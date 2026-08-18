import Foundation
import AppKit
import ImageIO
import os

enum SidebarTree: Hashable {
    case favorites(rootID: UUID)
    case open
}

struct FavoriteFolderExpansion: Hashable {
    let rootID: UUID
    let url: URL
}

nonisolated protocol ImageTrashHandling: Sendable {
    func trashItem(at url: URL) throws
}

nonisolated struct SystemImageTrashHandler: ImageTrashHandling {
    func trashItem(at url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}

@Observable
final class BrowserViewModel {
    struct MetadataLoadingProgress: Equatable {
        let completed: Int
        let total: Int

        var fraction: Double {
            guard total > 0 else { return 0 }
            return min(max(Double(completed) / Double(total), 0), 1)
        }
    }

    var images: [ImageFile] = [] {
        didSet {
            guard !suppressImagesCascade else { return }
            urlToImageIndex = Dictionary(uniqueKeysWithValues: images.enumerated().map { ($1.url, $0) })
            guard !isBatchUpdating else { return }
            let sameSet = images.count == oldValue.count
            setNeedsSortRebuild(forceSort: !sameSet)
        }
    }
    var selectedImageIDs: Set<URL> = [] {
        didSet {
            if selectedImageIDs != oldValue {
                rebuildSelectedCache()
            }
        }
    }
    var lastClickedImageURL: URL?
    var currentFolderURL: URL?
    var currentFolderName: String?
    var isLoading = false
    var isFullScreen = false
    var shouldRestoreGridFocus = false
    var iCloudDownloadNotice: String?
    /// Non-blocking second phase after the file grid appears. Exposed so the browser can
    /// explain why rating/label/metadata-dependent filters are still settling.
    var metadataLoadingProgress: MetadataLoadingProgress?

    struct FullScreenFaceNavigationItem {
        let imageURL: URL
        let faceID: UUID
    }

    struct FullScreenFaceContext {
        let faceRecognitionViewModel: FaceRecognitionViewModel
        var highlightedFaceID: UUID?
        let navigationItems: [FullScreenFaceNavigationItem]?
        let onNavigateToFace: ((UUID?) -> Void)?
    }

    @ObservationIgnored var fullScreenFaceContext: FullScreenFaceContext?
    var errorMessage: String?
    /// Reserved for failures that prevent the current folder from producing a usable
    /// grid. Ordinary operation failures use `errorMessage` and remain non-modal.
    var folderLoadErrorMessage: String?
    var sortOrder: SortOrder = .name {
        didSet {
            UserDefaults.standard.set(sortOrder.rawValue, forKey: UserDefaultsKeys.thumbnailSortOrder)
            guard !isBatchUpdating else { return }
            setNeedsSortRebuild(forceSort: true)
            showSortFeedback()
        }
    }
    var sortReversed: Bool = false {
        didSet {
            UserDefaults.standard.set(sortReversed, forKey: UserDefaultsKeys.thumbnailSortReversed)
            guard !isBatchUpdating else { return }
            setNeedsSortRebuild(forceSort: true)
            showSortFeedback()
        }
    }
    var sortFeedback: String?
    @ObservationIgnored private var sortFeedbackTask: Task<Void, Never>?
    var favoriteFolders: [FavoriteFolder] = []
    var openFolders: [URL] = []
    var subfoldersByOpenFolder: [URL: [URL]] = [:]
    var expandedFavoriteFolders: Set<FavoriteFolderExpansion> = []
    var expandedOpenFolders: Set<URL> = []
    var manualOrder: [URL] = [] {
        didSet {
            guard !isBatchUpdating else { return }
            if sortOrder == .manual { setNeedsSortRebuild(forceSort: true) }
        }
    }
    @ObservationIgnored var draggedImageURLs: Set<URL> = []
    var searchText: String = "" {
        didSet {
            guard !isBatchUpdating else { return }
            searchDebounceTask?.cancel()
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                setNeedsVisibleRebuild()
            } else {
                searchDebounceTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled else { return }
                    self?.setNeedsVisibleRebuild()
                }
            }
        }
    }
    var minimumStarRating: StarRating = .none {
        didSet { if !isBatchUpdating { setNeedsVisibleRebuild() } }
    }
    var selectedColorLabels: Set<ColorLabel> = [] {
        didSet { if !isBatchUpdating { setNeedsVisibleRebuild() } }
    }
    var personShownFilter: PersonShownFilter = .any {
        didSet { if !isBatchUpdating { setNeedsVisibleRebuild() } }
    }
    var editedFilter: EditedFilter = .any {
        didSet { if !isBatchUpdating { setNeedsVisibleRebuild() } }
    }
    /// Completeness check against the user's required-metadata fields (configured in Settings).
    var requiredMetadataFilter: RequiredMetadataFilter = .any {
        didSet { if !isBatchUpdating { setNeedsVisibleRebuild() } }
    }
    /// Fields the browser should filter to "missing". OR semantics, matching color-label selection:
    /// an image passes when it's missing at least one of these. Empty → inactive.
    var missingFieldFilters: Set<MetadataFieldID> = [] {
        didSet { if !isBatchUpdating { setNeedsVisibleRebuild() } }
    }

    @ObservationIgnored private var folderFilterStates: [URL: FolderFilterState] = [:]

    var thumbnailScale: Double = 1.0 {
        didSet {
            UserDefaults.standard.set(thumbnailScale, forKey: UserDefaultsKeys.thumbnailScale)
        }
    }

    var showAllFiles: Bool = false {
        didSet {
            UserDefaults.standard.set(showAllFiles, forKey: UserDefaultsKeys.showAllFiles)
            if let url = currentFolderURL { loadFolder(url: url) }
        }
    }

    var showOriginalThumbnails: Bool = false {
        didSet {
            UserDefaults.standard.set(showOriginalThumbnails, forKey: UserDefaultsKeys.showOriginalThumbnails)
        }
    }

    var copiedCameraRawSettings: CameraRawSettings?
    var copiedIPTCMetadata: IPTCMetadata?

    let fileSystemService = FileSystemService()
    /// Injected so split-view panes can share a single decode gate + NSCache rather than
    /// each pane spinning up its own (which would double concurrent decodes and thrash).
    let thumbnailService: ThumbnailService
    let metadataReadService = SwiftExifReadService()
    @ObservationIgnored private(set) var writeEngine: any MetadataWriteEngine = SwiftExifWriteEngine()
    /// Injected for the same reason as `thumbnailService` — sharing one IOSurface pool across
    /// panes avoids doubling full-screen-preview memory pressure.
    @ObservationIgnored let fullScreenImageCache: FullScreenImageCache
    /// Content token (size+mtime) the thumbnail caches were last populated under, per
    /// URL, surviving folder navigation. Lets `loadFolder` drop a stale thumbnail when a
    /// file was replaced at a path it previously occupied (delete + re-export) while the
    /// folder was inactive — the URL-keyed caches alone can't tell the file changed.
    /// Bounded (NSCache) so it can't grow without limit across a long session of folder
    /// hops; an evicted token at worst skips one stale-thumbnail invalidation, which the
    /// thumbnail NSCache self-heals on regeneration.
    @ObservationIgnored private let thumbnailContentTokens: NSCache<NSURL, NSString> = {
        let c = NSCache<NSURL, NSString>()
        c.countLimit = 20_000
        return c
    }()
    private let sidecarService = MetadataSidecarService()
    private let xmpSidecarService = XMPSidecarService()

    private let logger = Logger(subsystem: "com.aagedal.photo-agent", category: "BrowserViewModel")
    private let perfLog = Logger(subsystem: "com.aagedal.photo-agent", category: "MetadataPerf")
    @ObservationIgnored var onImagesDeleted: ((Set<URL>) -> Void)?
    @ObservationIgnored private let imageTrashHandler: any ImageTrashHandling

    @ObservationIgnored private var searchDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var needsSortRebuild = false
    @ObservationIgnored private var needsVisibleRebuild = false
    @ObservationIgnored private var needsForceSortOnRebuild = false
    @ObservationIgnored private var rebuildCoalesceTask: Task<Void, Never>?
    @ObservationIgnored private var isBatchUpdating = false
    @ObservationIgnored private(set) var lastRefreshModifiedURLs: Set<URL> = []

    /// Clear after the auto-refresh modifier has processed the modified URLs,
    /// so stale entries don't trigger repeated metadata reloads.
    func clearLastRefreshModifiedURLs() {
        lastRefreshModifiedURLs = []
    }
    @ObservationIgnored private var isAutoRefreshing = false
    @ObservationIgnored private var isMetadataLoading = false
    @ObservationIgnored private var metadataProgressID: UUID?
    @ObservationIgnored private var pendingMetadataURLs: Set<URL> = []
    @ObservationIgnored private var retinaPreCacheTask: Task<Void, Never>?
    @ObservationIgnored private var suppressImagesCascade = false
    @ObservationIgnored private var pendingMetadataDrainTask: Task<Void, Never>?
    @ObservationIgnored private var autoRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var metadataWriteTask: Task<Void, Never>?
    @ObservationIgnored private var batchReadTask: Task<Void, Never>?
    @ObservationIgnored private var pendingStatusRefreshTask: Task<Void, Never>?

    private let favoritesKey = UserDefaultsKeys.favoriteFolders

    private(set) var sortedImages: [ImageFile] = []
    private(set) var urlToSortedIndex: [URL: Int] = [:]
    private(set) var urlToImageIndex: [URL: Int] = [:]
    private(set) var visibleImages: [ImageFile] = []
    private(set) var urlToVisibleIndex: [URL: Int] = [:]

    var isFilteringActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || minimumStarRating != .none
            || !selectedColorLabels.isEmpty
            || personShownFilter != .any
            || editedFilter != .any
            || requiredMetadataFilter != .any
            || !missingFieldFilters.isEmpty
    }

    @ObservationIgnored private(set) var selectedImagesCache: [ImageFile] = []

    init(thumbnailService: ThumbnailService = ThumbnailService(),
         fullScreenImageCache: FullScreenImageCache = FullScreenImageCache(),
         imageTrashHandler: any ImageTrashHandling = SystemImageTrashHandler()) {
        self.thumbnailService = thumbnailService
        self.fullScreenImageCache = fullScreenImageCache
        self.imageTrashHandler = imageTrashHandler
        if let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.thumbnailSortOrder),
           let stored = SortOrder(rawValue: raw) {
            sortOrder = stored
        }
        sortReversed = UserDefaults.standard.bool(forKey: UserDefaultsKeys.thumbnailSortReversed)
        let storedScale = UserDefaults.standard.double(forKey: UserDefaultsKeys.thumbnailScale)
        if storedScale >= 0.5 && storedScale <= 2.0 {
            thumbnailScale = storedScale
        }
        self.showOriginalThumbnails = UserDefaults.standard.bool(forKey: UserDefaultsKeys.showOriginalThumbnails)
        self.showAllFiles = UserDefaults.standard.bool(forKey: UserDefaultsKeys.showAllFiles)
    }

    deinit {
        sortFeedbackTask?.cancel()
        searchDebounceTask?.cancel()
        rebuildCoalesceTask?.cancel()
        retinaPreCacheTask?.cancel()
        loadFolderTask?.cancel()
        pendingMetadataDrainTask?.cancel()
        autoRefreshTask?.cancel()
        metadataWriteTask?.cancel()
        batchReadTask?.cancel()
    }

    var selectedImages: [ImageFile] { selectedImagesCache }

    var firstSelectedImage: ImageFile? {
        guard let firstID = selectedImageIDs.first else { return nil }
        if let index = urlToImageIndex[firstID] { return images[index] }
        return nil
    }

    private func rebuildSortedCache(forceSort: Bool = true) {
        let needsSort = forceSort || sortOrder == .rating || sortOrder == .label
        if needsSort {
            let sorted: [ImageFile]
            switch sortOrder {
            case .name:
                sorted = images.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
            case .dateModified:
                sorted = images.sorted { $0.dateModified > $1.dateModified }
            case .dateAdded:
                sorted = images.sorted { $0.dateAdded > $1.dateAdded }
            case .rating:
                sorted = images.sorted { $0.starRating.rawValue > $1.starRating.rawValue }
            case .label:
                sorted = images.sorted { ($0.colorLabel.shortcutIndex ?? 0) < ($1.colorLabel.shortcutIndex ?? 0) }
            case .fileType:
                sorted = images.sorted {
                    let ext0 = $0.url.pathExtension.lowercased()
                    let ext1 = $1.url.pathExtension.lowercased()
                    if ext0 != ext1 {
                        return ext0.localizedStandardCompare(ext1) == .orderedAscending
                    }
                    return $0.filename.localizedStandardCompare($1.filename) == .orderedAscending
                }
            case .manual:
                if manualOrder.isEmpty {
                    sorted = images
                } else {
                    let imagesByURL = Dictionary(uniqueKeysWithValues: images.map { ($0.url, $0) })
                    var result = manualOrder.compactMap { imagesByURL[$0] }
                    let manualSet = Set(manualOrder)
                    result.append(contentsOf: images.filter { !manualSet.contains($0.url) })
                    sorted = result
                }
            }
            let final = (sortReversed && sortOrder != .manual) ? sorted.reversed() : sorted
            sortedImages = Array(final)
            urlToSortedIndex = Dictionary(uniqueKeysWithValues: sortedImages.enumerated().map { ($1.url, $0) })
        } else {
            // Same images, just updated properties — refresh sortedImages in existing order
            let imageByURL = Dictionary(uniqueKeysWithValues: images.map { ($0.url, $0) })
            sortedImages = sortedImages.compactMap { imageByURL[$0.url] }
        }
        rebuildVisibleCache()
    }

    private func showSortFeedback() {
        sortFeedbackTask?.cancel()
        sortFeedback = sortOrder.overlayDescription(reversed: sortReversed)
        sortFeedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.sortFeedback = nil
        }
    }

    private func setNeedsSortRebuild(forceSort: Bool = true) {
        needsSortRebuild = true
        if forceSort { needsForceSortOnRebuild = true }
        scheduleCoalescedRebuild()
    }

    private func setNeedsVisibleRebuild() {
        needsVisibleRebuild = true
        scheduleCoalescedRebuild()
    }

    private func scheduleCoalescedRebuild() {
        guard rebuildCoalesceTask == nil else { return }
        rebuildCoalesceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.rebuildCoalesceTask = nil
            self.flushRebuild()
        }
    }

    private func flushRebuild() {
        if needsSortRebuild {
            let forceSort = needsForceSortOnRebuild
            needsSortRebuild = false
            needsVisibleRebuild = false
            needsForceSortOnRebuild = false
            rebuildSortedCache(forceSort: forceSort)
        } else if needsVisibleRebuild {
            needsVisibleRebuild = false
            rebuildVisibleCache()
        }
    }

    private func rebuildNow() {
        rebuildCoalesceTask?.cancel()
        rebuildCoalesceTask = nil
        flushRebuild()
    }

    func batchUpdate(_ block: () -> Void) {
        isBatchUpdating = true
        block()
        isBatchUpdating = false
        // The per-property didSets are gated on `!isBatchUpdating`, so the changes above
        // requested no rebuild. Mark one explicitly, otherwise `rebuildNow()` finds no
        // pending flag and the grid keeps showing the pre-batch filtered set (e.g. Clear
        // Filters appeared to do nothing). A pending sort rebuild still takes precedence
        // in `flushRebuild()` and also refreshes the visible cache.
        needsVisibleRebuild = true
        rebuildNow()
    }

    private func rebuildVisibleCache() {
        let previousVisibleURLs = visibleImages.map(\.url)
        let fullScreenAnchor = isFullScreen
            ? (lastClickedImageURL ?? selectedImageIDs.first)
            : nil
        let filtered = applyFilters(to: sortedImages)
        visibleImages = filtered
        urlToVisibleIndex = Dictionary(uniqueKeysWithValues: filtered.enumerated().map { ($1.url, $0) })

        let visibleSet = Set(filtered.map(\.url))
        if let fullScreenAnchor,
           previousVisibleURLs.contains(fullScreenAnchor),
           !visibleSet.contains(fullScreenAnchor) {
            // Rating/label changes can make the image being viewed fail the active
            // filter. Keep full screen anchored in the old filmstrip by moving to the
            // nearest surviving image (next wins ties), rather than allowing selection
            // reconciliation to clear the viewer to a black screen.
            let removedURLs = Set(previousVisibleURLs).subtracting(visibleSet)
            let replacementURL = Self.closestSurvivingImageURL(
                in: previousVisibleURLs,
                around: fullScreenAnchor,
                deleting: removedURLs
            ) ?? filtered.first?.url

            if let replacementURL {
                lastClickedImageURL = replacementURL
                selectedImageIDs = [replacementURL]
            } else {
                // No images satisfy the filter anymore, so there is nothing valid for
                // the full-screen window to display.
                selectedImageIDs = []
                lastClickedImageURL = nil
                isFullScreen = false
            }
            return
        }

        if !selectedImageIDs.isEmpty {
            let intersection = selectedImageIDs.intersection(visibleSet)
            if intersection != selectedImageIDs {
                selectedImageIDs = intersection
            } else {
                rebuildSelectedCache()
            }
        } else {
            selectedImagesCache = []
        }
        if let anchor = lastClickedImageURL, !visibleSet.contains(anchor) {
            lastClickedImageURL = nil
        }
    }

    /// The live in-memory CameraRaw edit settings for a file, if it is currently loaded.
    /// Used by the export/publish pipeline to render the edits the user is seeing, even
    /// before they've been flushed to a sidecar.
    func currentCameraRawSettings(for url: URL) -> CameraRawSettings? {
        guard let index = urlToImageIndex[url] else { return nil }
        return images[index].cameraRawSettings
    }

    private func rebuildSelectedCache() {
        guard !selectedImageIDs.isEmpty else {
            selectedImagesCache = []
            return
        }
        selectedImagesCache = selectedImageIDs.compactMap { url in
            guard let index = urlToImageIndex[url] else { return nil }
            return images[index]
        }
        preCacheSelectedRetinaImage()
    }

    private func preCacheSelectedRetinaImage() {
        retinaPreCacheTask?.cancel()
        retinaPreCacheTask = nil

        guard selectedImageIDs.count == 1,
              let url = selectedImageIDs.first,
              let index = urlToImageIndex[url] else { return }
        // Full screen opens with edits rendered unless "show originals" is on —
        // pre-cache into the matching slot (an edited render must NEVER land in
        // the unedited slot, or stale edits shadow the original).
        let isEdited = !showOriginalThumbnails
        let imageFile = images[index]
        let orientation = FullScreenImageCache.displayOrientation(for: url, fallback: imageFile.exifOrientation)
        let cameraRaw = showOriginalThumbnails
            ? nil
            : (imageFile.cameraRawSettings ?? XMPSidecarService().loadSidecar(for: url)?.cameraRaw)
        let renderToken = FullScreenImageCache.renderToken(settings: cameraRaw, isEdited: isEdited)
        guard fullScreenImageCache.cachedImage(
            for: url,
            orientation: orientation,
            renderToken: renderToken,
            isEdited: isEdited
        ) == nil else { return }

        let screenScale = NSScreen.main?.backingScaleFactor ?? 2.0
        let screenLogicalPx = max(NSScreen.main?.frame.width ?? 3840,
                                   NSScreen.main?.frame.height ?? 2160)
        let screenMaxPx = screenLogicalPx * screenScale

        retinaPreCacheTask = Task.detached(priority: .utility) { [weak self] in
            guard let self, !Task.isCancelled else { return }
            // Render through the shared edited-decode path so the pre-cache is identical to
            // what prefetch/foreground produce — single source of truth. For edited RAW this
            // means CIRAWFilter demosaicing directly at screen resolution with as-shot WB +
            // EDR stamp (not ImageIO's full-sensor decode with neutral WB, which made first-open
            // look different from a navigate-away-and-back render and incurred a wasteful stall).
            // With nil settings (show-originals) it degrades to a plain downsampled decode.
            guard let image = await FullScreenImageCache.decodedEditedPreview(
                for: url, settings: cameraRaw, orientation: orientation, screenMaxPx: screenMaxPx
            ), !Task.isCancelled else { return }
            self.fullScreenImageCache.store(
                image,
                for: url,
                orientation: orientation,
                renderToken: renderToken,
                isEdited: isEdited
            )
        }
    }

    private struct ImageFilterContext {
        let query: String
        let requiredFields: Set<MetadataFieldID>
        let requiredLevels: MetadataRequirements.Levels
        let minimumLengths: MetadataRequirements.MinimumLengths
    }

    private func makeImageFilterContext() -> ImageFilterContext {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard requiredMetadataFilter != .any else {
            return ImageFilterContext(
                query: query,
                requiredFields: [],
                requiredLevels: [:],
                minimumLengths: [:]
            )
        }

        let requiredFields = MetadataRequirements.requireFields()
        return ImageFilterContext(
            query: query,
            requiredFields: requiredFields,
            requiredLevels: Dictionary(uniqueKeysWithValues: requiredFields.map { ($0, .require) }),
            minimumLengths: MetadataRequirements.loadMinimumLengths()
        )
    }

    private func imagePassesFilter(_ image: ImageFile, context: ImageFilterContext) -> Bool {
        if image.starRating.rawValue < minimumStarRating.rawValue {
            return false
        }
        if !selectedColorLabels.isEmpty && !selectedColorLabels.contains(image.colorLabel) {
            return false
        }
        switch personShownFilter {
        case .any:
            break
        case .missing:
            if !image.personShown.isEmpty { return false }
        case .present:
            if image.personShown.isEmpty { return false }
        }
        switch editedFilter {
        case .any:
            break
        case .edited:
            if !image.hasDevelopEdits && !image.hasCropEdits { return false }
        case .unedited:
            if image.hasDevelopEdits || image.hasCropEdits { return false }
        }
        // Required-metadata completeness against the user's configured fields. A nil metadata record
        // counts every field as missing, so such images are "incomplete" unless nothing is required.
        if requiredMetadataFilter != .any {
            let missingAny: Bool
            if let meta = image.metadata {
                missingAny = context.requiredFields.contains {
                    MetadataRequirements.fieldFails(
                        $0,
                        in: meta,
                        levels: context.requiredLevels,
                        minimumLengths: context.minimumLengths
                    )
                }
            } else {
                missingAny = !context.requiredFields.isEmpty
            }
            switch requiredMetadataFilter {
            case .any: break
            case .complete: if missingAny { return false }
            case .incomplete: if !missingAny { return false }
            }
        }
        // "Missing field" submenu — OR semantics: pass if missing at least one selected field.
        if !missingFieldFilters.isEmpty {
            let meta = image.metadata
            let missesOne = missingFieldFilters.contains { field in
                meta.map { field.isEmpty(in: $0) } ?? true
            }
            if !missesOne { return false }
        }
        guard !context.query.isEmpty else { return true }
        if image.filenameLowercased.contains(context.query) {
            return true
        }
        if image.personShownLowercased.contains(where: { $0.contains(context.query) }) {
            return true
        }
        if image.keywordsLowercased.contains(where: { $0.contains(context.query) }) {
            return true
        }
        // Search IPTC metadata fields (title, description, creator, city, country, event) via the
        // pre-lowercased blob built when metadata was assigned — `query` is already lowercased, so
        // this is a single substring scan instead of six locale-folding searches per image.
        if image.metadataSearchLowercased.contains(context.query) {
            return true
        }
        return false
    }

    private func applyFilters(to images: [ImageFile]) -> [ImageFile] {
        let context = makeImageFilterContext()
        return images.filter { imagePassesFilter($0, context: context) }
    }

    func clearFilters() {
        batchUpdate {
            searchText = ""
            minimumStarRating = .none
            selectedColorLabels.removeAll()
            personShownFilter = .any
            editedFilter = .any
            requiredMetadataFilter = .any
            missingFieldFilters.removeAll()
        }
    }

    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadFolder(url: url)
    }

    @ObservationIgnored private var loadFolderTask: Task<Void, Never>?

    func loadFolder(url: URL, addToOpenFolders: Bool = true) {
        // Cancel any in-flight folder load to prevent stale results overwriting
        loadFolderTask?.cancel()
        pendingMetadataDrainTask?.cancel()
        autoRefreshTask?.cancel()
        metadataWriteTask?.cancel()
        batchReadTask?.cancel()
        // Reset in case the cancelled task's metadata loop left this true,
        // otherwise the images.didSet below won't rebuild urlToImageIndex.
        suppressImagesCascade = false

        saveCurrentFilterState()

        currentFolderURL = url
        currentFolderName = url.lastPathComponent
        RecentFoldersStore.shared.track(url)
        isLoading = true
        errorMessage = nil
        folderLoadErrorMessage = nil
        iCloudDownloadNotice = nil
        metadataLoadingProgress = nil
        metadataProgressID = nil
        images = []
        selectedImageIDs.removeAll()
        lastClickedImageURL = nil
        manualOrder.removeAll()
        fullScreenImageCache.clearAll()

        restoreFilterState(for: url)

        // Add to open folders if not already there, unless it's a subfolder of
        // an existing open folder, or a favorite (root or descendant) — favorites
        // already have a home in the Favorites section and must not duplicate
        // into Open Folders, no matter which entry point opened them (tap,
        // Open Recent, drag-and-drop, import).
        let isFavoriteRoot = favoriteFolders.contains { $0.url == url }
        if addToOpenFolders && !isFavoriteRoot && !isSubfolderOfOpenFolder(url) {
            if !openFolders.contains(url) {
                openFolders.append(url)
            }
            // Announce so the shared sidebar (primary pane) lists this root even when a
            // non-primary split-view pane opened it. Idempotent on the primary.
            NotificationCenter.default.post(name: .browserDidOpenRootFolder, object: url)
        }

        loadFolderTask = Task {
            do {
                // Phase 1: Scan folder and show grid immediately
                let scanResult = try await fileSystemService.scanFolderWithStatus(at: url, includeAllFiles: showAllFiles)
                var files = scanResult.files
                guard !Task.isCancelled, self.currentFolderURL == url else { return }
                self.iCloudDownloadNotice = scanResult.hasDeferredICloudItems
                    ? Self.iCloudDownloadMessage(for: scanResult.deferredICloudItemCount)
                    : nil
                // Same-folder reload: carry over already-known display orientations.
                // scanFolder returns default orientation 1 and the eager/batch reads
                // that repopulate it are async — without this, a mid-session reload
                // transiently resets every rotation, and an open edit view re-renders
                // at the wrong orientation until those passes catch up. (No-op on a
                // genuine folder switch: no URLs match.)
                for index in files.indices {
                    if let existingIndex = self.urlToImageIndex[files[index].url] {
                        files[index].exifOrientation = self.images[existingIndex].exifOrientation
                    }
                }
                self.reconcileThumbnailCaches(against: files)
                self.images = files
                self.rebuildNow()
                self.isLoading = false

                // Phase 1.5: Read EXIF orientations in background (deferred).
                // Thumbnails don't need this (QL/CGImageSource apply transforms internally).
                // Phase 5 (metadata read) also sets it; this provides it sooner for full-screen entry.
                var orientedFiles = files
                await self.readOrientationsEagerly(for: &orientedFiles)
                guard !Task.isCancelled, self.currentFolderURL == url else { return }
                let nonDefault = orientedFiles.filter { $0.exifOrientation != 1 }
                if !nonDefault.isEmpty {
                    // Resolve each file by URL via urlToImageIndex rather than by the
                    // positional index from `orientedFiles`: `self.images` may have been
                    // replaced or reordered (auto-refresh merge, delete, sort) during the
                    // `await` above, so a stale positional index could write to the wrong
                    // image or crash out-of-bounds. urlToImageIndex always matches the
                    // current `self.images`. We only mutate a field (set unchanged), so the
                    // index stays valid across the loop even with the cascade suppressed.
                    self.suppressImagesCascade = true
                    for file in nonDefault {
                        guard let index = self.urlToImageIndex[file.url] else { continue }
                        if self.images[index].exifOrientation != file.exifOrientation {
                            self.logger.info("[\(file.url.lastPathComponent, privacy: .public)] eager orientation (loadFolder) \(self.images[index].exifOrientation) → \(file.exifOrientation)")
                            // See applyBatchMetadataResults: drop model-orientation-derived
                            // renders produced under the old value.
                            self.thumbnailService.invalidateEditedThumbnail(for: file.url)
                            self.fullScreenImageCache.invalidateImage(for: file.url)
                        }
                        self.images[index].exifOrientation = file.exifOrientation
                    }
                    self.suppressImagesCascade = false
                }

                // Phase 2: Discover subfolders after the grid is visible. `listSubfolders` is
                // synchronous; calling it directly from this main-actor task can block SwiftUI
                // while iCloud resolves directory placeholders. Force the enumeration onto a
                // utility task just as the initial image scan is forced off the main actor.
                let service = fileSystemService
                let discoveredSubfolders = await Task.detached(priority: .utility) {
                    (try? service.listSubfolders(at: url)) ?? []
                }.value
                guard !Task.isCancelled, self.currentFolderURL == url else { return }
                self.subfoldersByOpenFolder[url] = discoveredSubfolders
                if !discoveredSubfolders.isEmpty {
                    self.expandedOpenFolders.insert(url)
                }
                self.prefetchGrandchildren(of: url)

                // Phase 3: Load sidecars and apply pending overrides
                let allSidecars = await sidecarService.loadAllSidecars(in: url)
                var updated = self.images
                for i in updated.indices {
                    if let sidecar = allSidecars[updated[i].url], sidecar.pendingChanges {
                        updated[i].hasPendingMetadataChanges = true
                        updated[i].pendingFieldNames = extractPendingFieldNames(from: sidecar)
                        applySidecarCropAndDevelopState(to: &updated[i], sidecar: sidecar)
                    }
                }
                guard !Task.isCancelled, self.currentFolderURL == url else { return }
                self.images = updated
                self.rebuildNow()

                // Phase 4: Load metadata. Thumbnails and display previews are decoded only
                // for visible/prefetched items instead of warming the entire folder into
                // bounded memory caches.
                let metadataURLs = self.images
                    .filter { $0.isImageFile && !$0.isICloudDownloadPending }
                    .map(\.url)
                await loadBasicMetadata(
                    for: metadataURLs,
                    cachedSidecars: allSidecars,
                    showsProgress: true
                )
            } catch {
                guard !Task.isCancelled, self.currentFolderURL == url else { return }
                self.folderLoadErrorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    /// Stable identity of a file's bytes, from the scan's size+mtime (no extra I/O).
    /// Note: an in-browser develop edit doesn't touch the file, so its token is
    /// unchanged and its edited thumbnail survives navigation; a re-export changes it.
    nonisolated private static func thumbnailContentToken(for file: ImageFile) -> String {
        "\(file.fileSize)|\(file.dateModified.timeIntervalSinceReferenceDate)"
    }

    nonisolated private static func iCloudDownloadMessage(for deferredItemCount: Int) -> String {
        if deferredItemCount == 1 {
            return "An iCloud file is downloading. Thumbnails will appear as soon as the file is ready."
        }
        return "\(deferredItemCount) iCloud files are downloading. Thumbnails will appear as soon as the files are ready."
    }

    /// Drop URL-keyed thumbnail caches for files whose bytes changed since we last
    /// cached them (e.g. a render deleted and re-exported to the same path while this
    /// folder was inactive). Unchanged files keep their cache. Tokens persist across
    /// navigation, so this catches changes the in-place auto-refresh diff never saw.
    private func reconcileThumbnailCaches(against files: [ImageFile]) {
        for file in files {
            let token = Self.thumbnailContentToken(for: file)
            let key = file.url as NSURL
            if let previous = thumbnailContentTokens.object(forKey: key), (previous as String) != token {
                thumbnailService.invalidateThumbnail(for: file.url)
            }
            thumbnailContentTokens.setObject(token as NSString, forKey: key)
        }
    }

    @discardableResult
    func refreshCurrentFolderIfNeeded(onComplete: ((Set<URL>) -> Void)? = nil) -> Bool {
        guard let folderURL = currentFolderURL else { return false }
        guard !isLoading, !isMetadataLoading, !isAutoRefreshing else { return false }
        isAutoRefreshing = true
        autoRefreshTask?.cancel()

        autoRefreshTask = Task {
            var completedModifiedURLs: Set<URL> = []
            defer {
                self.isAutoRefreshing = false
                onComplete?(completedModifiedURLs)
            }

            let scanResult: FileSystemService.FolderScanResult
            do {
                scanResult = try await fileSystemService.scanFolderWithStatus(at: folderURL, includeAllFiles: showAllFiles)
            } catch {
                return
            }
            self.iCloudDownloadNotice = scanResult.hasDeferredICloudItems
                ? Self.iCloudDownloadMessage(for: scanResult.deferredICloudItemCount)
                : nil
            let scanned = scanResult.files

            let existingByURL = Dictionary(uniqueKeysWithValues: images.map { ($0.url, $0) })
            let existingURLs = Set(existingByURL.keys)
            let scannedURLs = Set(scanned.map(\.url))

            var merged: [ImageFile] = []
            merged.reserveCapacity(scanned.count)
            var newURLs: [URL] = []
            var modifiedURLs: [URL] = []
            // Sidecar-only changes (e.g. ACR rotated/edited a RAW): the image file's
            // size/mtime are untouched, only the adjacent `.xmp` moved. Handled apart
            // from content changes so we re-read the sidecar *in place* instead of
            // pre-clearing develop state — pre-clearing would flash the develop-edited
            // RAWs on our own sidecar writes (rotate/rating/caption), which also bump
            // the sidecar mtime.
            var sidecarChangedURLs: [URL] = []

            for item in scanned {
                if let existing = existingByURL[item.url] {
                    let contentModified = existing.fileSize != item.fileSize
                        || existing.dateModified != item.dateModified
                    let sidecarChanged = !contentModified
                        && existing.sidecarModified != item.sidecarModified
                    var updated = item
                    updated.starRating = existing.starRating
                    updated.colorLabel = existing.colorLabel
                    updated.hasC2PA = existing.hasC2PA
                    updated.hasDevelopEdits = existing.hasDevelopEdits
                    updated.hasCropEdits = existing.hasCropEdits
                    updated.cropRegion = existing.cropRegion
                    updated.cameraRawSettings = existing.cameraRawSettings
                    updated.exifOrientation = existing.exifOrientation
                    updated.isNativeHDR = existing.isNativeHDR
                    updated.hasPendingMetadataChanges = existing.hasPendingMetadataChanges
                    updated.pendingFieldNames = existing.pendingFieldNames
                    updated.metadata = existing.metadata
                    updated.personShown = existing.personShown
                    updated.keywords = existing.keywords
                    if contentModified {
                        // File changed on disk — clear stale develop/crop state so
                        // thumbnails reflect the actual file content
                        updated.cameraRawSettings = nil
                        updated.hasDevelopEdits = false
                        updated.hasCropEdits = false
                        updated.cropRegion = nil
                        modifiedURLs.append(item.url)
                    } else if sidecarChanged {
                        // Keep the in-memory develop/orientation state as-is; the metadata
                        // reload below re-reads the sidecar and updates it in place, so a
                        // value that didn't actually change (our own write) causes no churn.
                        sidecarChangedURLs.append(item.url)
                    }
                    merged.append(updated)
                } else {
                    // Orientation is read off the main actor after the merge loop (see
                    // below) so a slow/network file can't block the UI with synchronous
                    // per-file CGImageSource I/O on the MainActor.
                    merged.append(item)
                    newURLs.append(item.url)
                }
            }

            let removedURLs = existingURLs.subtracting(scannedURLs)
            if newURLs.isEmpty && modifiedURLs.isEmpty && sidecarChangedURLs.isEmpty && removedURLs.isEmpty {
                return
            }
            guard self.currentFolderURL == folderURL else { return }

            // Read orientations for newly-appeared files off the main actor (mirrors the
            // initial-load eager read) so new thumbnails render upright immediately without
            // blocking the UI on per-file CGImageSource I/O.
            if !newURLs.isEmpty {
                let orientations = await Self.readOrientations(for: newURLs)
                if !orientations.isEmpty {
                    for index in merged.indices {
                        if let orientation = orientations[merged[index].url] {
                            if merged[index].exifOrientation != orientation {
                                logger.info("[\(merged[index].url.lastPathComponent, privacy: .public)] eager orientation (refresh newURLs) \(merged[index].exifOrientation) → \(orientation)")
                            }
                            merged[index].exifOrientation = orientation
                        }
                    }
                }
            }

            let allSidecars = await sidecarService.loadAllSidecars(in: folderURL)
            for index in merged.indices {
                let url = merged[index].url
                if let sidecar = allSidecars[url], sidecar.pendingChanges {
                    merged[index].hasPendingMetadataChanges = true
                    merged[index].pendingFieldNames = extractPendingFieldNames(from: sidecar)
                } else {
                    merged[index].hasPendingMetadataChanges = false
                    merged[index].pendingFieldNames = []
                }
            }

            self.images = merged

            // Invalidate thumbnail + full-screen caches for changed files so they
            // regenerate with the current pixels/orientation (a sidecar rotation
            // changes the rendered orientation without touching the file). For
            // sidecar-only changes this is a one-time drop — the new mtime is now
            // stored, so an unchanged value won't re-trigger next cycle.
            let changedURLs = modifiedURLs + sidecarChangedURLs
            for url in changedURLs {
                thumbnailService.invalidateThumbnail(for: url)
                fullScreenImageCache.invalidateImage(for: url)
            }

            self.lastRefreshModifiedURLs = Set(changedURLs)
            completedModifiedURLs = self.lastRefreshModifiedURLs

            let pendingICloudURLs = Set(scanned.filter(\.isICloudDownloadPending).map(\.url))
            let metadataRefreshURLs = (newURLs + changedURLs).filter { !pendingICloudURLs.contains($0) }
            if !metadataRefreshURLs.isEmpty {
                pendingMetadataURLs.formUnion(metadataRefreshURLs)
                drainPendingMetadataIfNeeded()
            }
        }
        return true
    }

    /// Read EXIF orientation via CGImageSource (metadata-only, ~0.1ms/file).
    /// Called eagerly after folder scan so exifOrientation is correct before
    /// the full batch metadata read.
    private func readOrientationsEagerly(for images: inout [ImageFile]) async {
        let urls = images.compactMap { $0.isImageFile && !$0.isICloudDownloadPending ? $0.url : nil }
        let orientations = await Self.readOrientations(for: urls)
        guard !orientations.isEmpty else { return }
        for index in images.indices where images[index].isImageFile {
            if let orientation = orientations[images[index].url] {
                images[index].exifOrientation = orientation
            }
        }
    }

    /// Read the display orientation for the given image URLs off the main actor, with
    /// bounded parallelism. The XMP sidecar is authoritative when present (RAW/C2PA
    /// rotations are sidecar-only and never touch the file), falling back to the file's embedded tag —
    /// mirroring `ThumbnailService.orientedToSidecar` so the model, the thumbnails, and
    /// the edit view all derive orientation from the same source. Reading only the
    /// embedded tag here silently reverted sidecar rotations whenever this eager read
    /// ran after the XMP-aware batch pass (edit view upside down vs. its own thumbnail).
    /// Returns only non-default (≠1) orientations; callers leave the rest at the default
    /// upright value. `nonisolated` so the per-file I/O runs on the global executor,
    /// never blocking the MainActor — shared by the initial eager read and the
    /// incremental auto-refresh path.
    private nonisolated static func readOrientations(for urls: [URL]) async -> [URL: Int] {
        guard !urls.isEmpty else { return [:] }
        return await withTaskGroup(of: (URL, Int)?.self) { group in
            var iterator = urls.makeIterator()
            let concurrencyLimit = min(8, urls.count)

            for _ in 0..<concurrencyLimit {
                guard let url = iterator.next() else { break }
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    return Self.readOrientation(for: url)
                }
            }

            var result: [URL: Int] = [:]
            while let pair = await group.next() {
                if let pair { result[pair.0] = pair.1 }

                guard !Task.isCancelled else {
                    group.cancelAll()
                    break
                }
                if let url = iterator.next() {
                    group.addTask {
                        guard !Task.isCancelled else { return nil }
                        return Self.readOrientation(for: url)
                    }
                }
            }
            return result
        }
    }

    private nonisolated static func readOrientation(for url: URL) -> (URL, Int)? {
        if let sidecarOrientation = XMPSidecarService().sidecarOrientation(for: url) {
            return sidecarOrientation != 1 ? (url, sidecarOrientation) : nil
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let orientation = props[kCGImagePropertyOrientation] as? Int,
              orientation != 1 else { return nil }
        return (url, orientation)
    }

    /// Reads IPTC/XMP basic metadata for the given URLs in batches of 50 and merges
    /// each batch into `self.images`. Pass `cachedSidecars` when the caller has already
    /// loaded all sidecars for the folder (initial-load path); the incremental path
    /// leaves it empty and relies on `applyPendingSidecarOverrides`'s per-file fallback.
    private func loadBasicMetadata(
        for urls: [URL],
        cachedSidecars: [URL: MetadataSidecar] = [:],
        showsProgress: Bool = false
    ) async {
        guard metadataReadService.isAvailable else { return }
        guard !urls.isEmpty else { return }
        if isMetadataLoading {
            pendingMetadataURLs.formUnion(urls)
            return
        }
        isMetadataLoading = true
        let folderURL = currentFolderURL
        let progressID: UUID? = showsProgress ? UUID() : nil
        if let progressID {
            metadataProgressID = progressID
            metadataLoadingProgress = MetadataLoadingProgress(completed: 0, total: urls.count)
        }
        defer {
            isMetadataLoading = false
            if let progressID, metadataProgressID == progressID {
                metadataLoadingProgress = nil
                metadataProgressID = nil
            }
            drainPendingMetadataIfNeeded()
        }

        do {
            try metadataReadService.start()
        } catch {
            return
        }

        // Process in batches — apply each batch directly to self.images so concurrent
        // user edits (rating/label changes) are not overwritten by a stale snapshot.
        // Suppress the images didSet cascade during the loop to avoid N/batchSize
        // redundant sort + filter + UI rebuild cycles; do a single rebuild at the end.
        let batchSize = 50
        let totalBatches = (urls.count + batchSize - 1) / batchSize
        let totalBatchStart = ContinuousClock.now
        perfLog.info("[BrowserVM] loadBasicMetadata START — \(urls.count) images, \(totalBatches) batches")

        suppressImagesCascade = true
        defer { suppressImagesCascade = false }
        for batchStart in stride(from: 0, to: urls.count, by: batchSize) {
            guard !Task.isCancelled, currentFolderURL == folderURL else { return }
            let batchEnd = min(batchStart + batchSize, urls.count)
            let batchURLs = Array(urls[batchStart..<batchEnd])
            let batchIndex = batchStart / batchSize
            let batchTimer = ContinuousClock.now

            do {
                async let xmpDataLoad = loadXMPSidecarDataBatch(for: batchURLs)
                let results = try await metadataReadService.readBatchBasicMetadata(urls: batchURLs)
                let xmpDataMap = await xmpDataLoad
                let imageAspects = Dictionary(uniqueKeysWithValues: results.compactMap { dict -> (URL, Double)? in
                    guard let sourcePath = dict[MetadataDictKey.sourceFile] as? String,
                          let aspect = metadataDictPixelAspect(dict) else { return nil }
                    return (URL(fileURLWithPath: sourcePath), aspect)
                })
                let xmpMetadataMap = await Self.parseXMPSidecarMetadataBatch(
                    xmpDataMap,
                    imageAspects: imageAspects
                )
                let batchMs = batchTimer.elapsedMilliseconds()
                perfLog.info("[BrowserVM] batch \(batchIndex)/\(totalBatches) DONE — \(batchURLs.count) files in \(batchMs)ms")
                applyBatchMetadataResults(
                    results,
                    to: &images,
                    localIndex: urlToImageIndex,
                    cachedSidecars: cachedSidecars,
                    xmpMetadataMap: xmpMetadataMap
                )
            } catch {
                logger.warning("Batch metadata load failed (batch at offset \(batchStart)): \(error.localizedDescription)")
            }
            if let progressID, metadataProgressID == progressID {
                metadataLoadingProgress = MetadataLoadingProgress(
                    completed: batchEnd,
                    total: urls.count
                )
            }
        }
        let totalMs = totalBatchStart.elapsedMilliseconds()
        perfLog.info("[BrowserVM] loadBasicMetadata DONE — \(urls.count) images in \(totalMs)ms")
        rebuildSortedCache()
    }

    /// Reads each batch's XMP sidecar bytes off the main actor in parallel.
    /// `Data(contentsOf:)` can stall on iCloud-not-downloaded sidecars; serializing
    /// these reads on MainActor inside `applyBatchMetadataResults` was producing
    /// 30+s freezes on first folder open. Parallelize the I/O so the slowest
    /// single sidecar bounds the batch instead of the sum.
    private func loadXMPSidecarDataBatch(for urls: [URL]) async -> [URL: Data] {
        let svc = xmpSidecarService
        return await withTaskGroup(of: (URL, Data?).self) { group in
            for url in urls {
                group.addTask {
                    (url, svc.sidecarDataIfExists(for: url))
                }
            }
            var map: [URL: Data] = [:]
            for await (url, data) in group {
                if let data { map[url] = data }
            }
            return map
        }
    }

    /// Parses already-read sidecars outside the main actor. The embedded metadata aspect
    /// is preferred for angled-crop conversion; only sidecars that need an aspect and lack
    /// one in the embedded metadata touch the image header as a fallback.
    private nonisolated static func parseXMPSidecarMetadataBatch(
        _ dataByURL: [URL: Data],
        imageAspects: [URL: Double]
    ) async -> [URL: IPTCMetadata] {
        let service = XMPSidecarService()
        return await withTaskGroup(of: (URL, IPTCMetadata?).self) { group in
            for (url, data) in dataByURL {
                group.addTask {
                    guard !Task.isCancelled else { return (url, nil) }
                    let metadata = service.loadSidecar(
                        fromData: data,
                        imageAspect: { imageAspects[url] ?? ImagePixelAspect.aspect(at: url) }
                    )
                    return (url, metadata)
                }
            }

            var result: [URL: IPTCMetadata] = [:]
            result.reserveCapacity(dataByURL.count)
            for await (url, metadata) in group {
                if let metadata { result[url] = metadata }
            }
            return result
        }
    }

    private func drainPendingMetadataIfNeeded() {
        guard !isMetadataLoading else { return }
        guard !pendingMetadataURLs.isEmpty else { return }
        let urls = Array(pendingMetadataURLs)
        pendingMetadataURLs.removeAll()
        pendingMetadataDrainTask?.cancel()
        pendingMetadataDrainTask = Task {
            await loadBasicMetadata(for: urls)
        }
    }

    /// Apply parsed batch metadata results to the local ImageFile array.
    /// Shared by full-folder reload and incremental (pending URL) reload paths.
    private func applyBatchMetadataResults(
        _ results: [[String: Any]],
        to updated: inout [ImageFile],
        localIndex: [URL: Int],
        cachedSidecars: [URL: MetadataSidecar] = [:],
        xmpMetadataMap: [URL: IPTCMetadata] = [:]
    ) {
        for dict in results {
            guard let sourcePath = dict[MetadataDictKey.sourceFile] as? String else { continue }
            let sourceURL = URL(fileURLWithPath: sourcePath)

            // Bounds-check: localIndex can become stale when images are modified during
            // an async metadata await (e.g. user switches folder while batch is in-flight).
            if let index = localIndex[sourceURL], index < updated.count {
                if let rating = dict[MetadataDictKey.rating] as? Int,
                   let starRating = StarRating(rawValue: rating) {
                    updated[index].starRating = starRating
                }
                updated[index].colorLabel = ColorLabel.fromMetadataLabel(dict[MetadataDictKey.label] as? String)
                updated[index].personShown = parseStringOrArray(dict[MetadataDictKey.personInImage])
                updated[index].keywords = mergedKeywords(from: dict)
                updated[index].hasC2PA = TechnicalMetadata.dictHasC2PA(dict)
                updated[index].hasDevelopEdits = hasDevelopEdits(in: dict)
                updated[index].hasCropEdits = hasCropEdits(in: dict)
                let previousOrientation = updated[index].exifOrientation
                updated[index].exifOrientation = parseIntValue(dict[MetadataDictKey.orientation]) ?? 1
                updated[index].isNativeHDR = SupportedImageFormats.isHDR(url: sourceURL)
                    || (UserDefaults.standard.bool(forKey: UserDefaultsKeys.rawRenderAsHDR) && SupportedImageFormats.isRaw(url: sourceURL))
                updated[index].cropRegion = cropRegion(in: dict, exifOrientation: updated[index].exifOrientation)
                // Preserve in-memory localAdjustments — these are set by the edit
                // workspace and written to the image directly, not parsed from
                // batch XMP output.
                let existingLocalAdjustments = updated[index].cameraRawSettings?.localAdjustments
                var newSettings = cameraRawSettings(in: dict)
                if (existingLocalAdjustments?.isEmpty == false) && newSettings == nil {
                    newSettings = CameraRawSettings()
                }
                if let masks = existingLocalAdjustments, !masks.isEmpty {
                    newSettings?.localAdjustments = masks
                }
                updated[index].cameraRawSettings = newSettings

                // XMP I/O and XML parsing completed off-main before this model merge.
                let xmpMeta = xmpMetadataMap[sourceURL]

                // metadata reads CRS from the image file itself but NOT from the
                // adjacent .xmp sidecar where edited CameraRaw settings are stored.
                // For RAW files, the XMP sidecar is the authoritative CRS source —
                // replace rather than merge to avoid stale embedded values leaking
                // through nil sidecar fields (e.g. Adobe omitting Temperature).
                if SupportedImageFormats.isRaw(url: sourceURL) {
                    if let xmpCRS = xmpMeta?.cameraRaw, !xmpCRS.isEmpty {
                        var finalCRS = xmpCRS
                        // Preserve in-memory localAdjustments (written to image, not sidecar)
                        if (xmpCRS.localAdjustments?.isEmpty ?? true),
                           let masks = updated[index].cameraRawSettings?.localAdjustments, !masks.isEmpty {
                            finalCRS.localAdjustments = masks
                        }
                        updated[index].cameraRawSettings = finalCRS
                        applySidecarCropState(to: &updated[index], cameraRaw: finalCRS)
                    } else {
                        // The sidecar holds no develop settings — the RAW is unedited or
                        // was cleared externally (e.g. an ACR reset). Since the sidecar is
                        // authoritative for RAW, drop any stale in-memory edits rather than
                        // leaving them. (No-op on first load, where CRS is already nil.)
                        updated[index].cameraRawSettings = nil
                        applySidecarCropState(to: &updated[index], cameraRaw: nil)
                    }
                } else if let xmpCRS = xmpMeta?.cameraRaw, !xmpCRS.isEmpty {
                    // Non-RAW develop edits also persist to the .xmp sidecar — the file is
                    // never rewritten by the editor. Apply the sidecar CRS so the in-memory
                    // state (and the develop-edit badge via applySidecarCropState) survive a
                    // background folder reload, which otherwise resets them to the file's
                    // embedded crs (empty for sidecar-only edits). Unlike RAW we DON'T clear
                    // on an absent/empty sidecar: a non-RAW file can legitimately carry
                    // embedded crs (e.g. an ACR-edited JPEG), already loaded from the dict above.
                    var finalCRS = xmpCRS
                    if (xmpCRS.localAdjustments?.isEmpty ?? true),
                       let masks = updated[index].cameraRawSettings?.localAdjustments, !masks.isEmpty {
                        finalCRS.localAdjustments = masks
                    }
                    updated[index].cameraRawSettings = finalCRS
                    applySidecarCropState(to: &updated[index], cameraRaw: finalCRS)
                }

                // XMP sidecar rating/label/orientation overrides — written by
                // writeToXMPSidecar mode for C2PA images (and any other images
                // using that mode).  Metadata only reads from the image file,
                // not adjacent .xmp files.
                if let xmpMeta {
                    if let xmpRating = xmpMeta.rating,
                       let starRating = StarRating(rawValue: xmpRating) {
                        updated[index].starRating = starRating
                    }
                    if let xmpLabel = xmpMeta.label, !xmpLabel.isEmpty {
                        updated[index].colorLabel = ColorLabel.fromMetadataLabel(xmpLabel)
                    }
                    if let xmpOrientation = xmpMeta.exifOrientation {
                        updated[index].exifOrientation = xmpOrientation
                        // Recompute crop region with corrected orientation
                        updated[index].cropRegion = cropRegion(
                            in: dict, exifOrientation: xmpOrientation)
                    }
                }
                if updated[index].exifOrientation != previousOrientation {
                    let newOrientation = updated[index].exifOrientation
                    let dictOrientation = parseIntValue(dict[MetadataDictKey.orientation]) ?? -1
                    logger.info("[\(sourceURL.lastPathComponent, privacy: .public)] batch metadata orientation \(previousOrientation) → \(newOrientation) (dict=\(dictOrientation), xmp=\(xmpMeta?.exifOrientation ?? -1))")
                    // Renders keyed off the model orientation (edited grid thumbs, loupe
                    // prefetch/warm entries) were produced under the old value — drop them
                    // or the loupe serves a stale-orientation frame until something else
                    // forces a re-render. Base thumbnails/previews read the sidecar at
                    // generation time and don't need this.
                    thumbnailService.invalidateEditedThumbnail(for: sourceURL)
                    fullScreenImageCache.invalidateImage(for: sourceURL)
                }

                // Populate the descriptive IPTC record for the grid. Without this, `metadata`
                // stays nil on a fresh folder load — only the inspector filled it lazily on
                // selection — so the metadata search blob was empty and the Required Metadata
                // filter judged every image "incomplete" (hiding them all under "Has required
                // metadata"). Mirror the inspector's merge (`loadMetadataSnapshot`): a
                // descriptive sidecar IS the record (clears stick), a develop-only sidecar
                // overlays additively.
                var descriptive = iptcMetadataFromDict(dict)
                if let xmpMeta {
                    descriptive = xmpMeta.hasDescriptiveContent
                        ? descriptive.replacingDescriptiveFields(from: xmpMeta)
                        : descriptive.merged(preferring: xmpMeta)
                }
                updated[index].metadata = descriptive

                applyPendingSidecarOverrides(to: &updated, for: sourceURL, index: index, cachedSidecar: cachedSidecars[sourceURL])
            }
        }
    }

    private func parseStringOrArray(_ value: Any?) -> [String] {
        if let array = value as? [String] {
            return array
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        if let str = value as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }
        return []
    }

    /// Merge IPTC:Keywords and XMP:Subject into a single deduplicated keyword list.
    private func mergedKeywords(from dict: [String: Any]) -> [String] {
        let iptc = parseStringOrArray(dict[MetadataDictKey.keywords])
        let xmp = parseStringOrArray(dict[MetadataDictKey.subject])
        guard !xmp.isEmpty else { return iptc }
        guard !iptc.isEmpty else { return xmp }
        // Merge, preserving IPTC order, then append any XMP-only entries
        var seen = Set(iptc.map { $0.lowercased() })
        var result = iptc
        for kw in xmp where !seen.contains(kw.lowercased()) {
            seen.insert(kw.lowercased())
            result.append(kw)
        }
        return result
    }

    private func hasDevelopEdits(in dict: [String: Any]) -> Bool {
        // A crs block marked AlreadyApplied="True" is baked into the exported pixels
        // (our own export, or ACR's rendered JPEG from RAW) — it documents history,
        // not live develop edits, so it must not light up the edited badge.
        if crsIsAlreadyApplied(in: dict) {
            return false
        }
        if parseBoolValue(dict[MetadataDictKey.crsHasSettings]) == true {
            return true
        }
        // Crop is handled by the identity-aware check below — a full-frame crop (or
        // merely opening the crop tool, which persists crsHasCrop=True with a
        // 0,0,1,1 rect) is a no-op and must not light the edited badge.
        let numericKeys: [String] = [
            MetadataDictKey.crsExposure2012,
            MetadataDictKey.crsContrast2012,
            MetadataDictKey.crsHighlights2012,
            MetadataDictKey.crsShadows2012,
            MetadataDictKey.crsWhites2012,
            MetadataDictKey.crsBlacks2012,
            MetadataDictKey.crsSharpness,
            MetadataDictKey.crsClarity2012,
            MetadataDictKey.crsDehaze,
            MetadataDictKey.crsTemperature,
            MetadataDictKey.crsTint,
            MetadataDictKey.crsIncrementalTemperature,
            MetadataDictKey.crsIncrementalTint,
        ]
        for key in numericKeys {
            if let value = parseDoubleValue(dict[key]), abs(value) > 0.0001 {
                return true
            }
        }
        return hasCropEdits(in: dict)
    }

    private func hasCropEdits(in dict: [String: Any]) -> Bool {
        // A crs block marked AlreadyApplied="True" is baked into the pixels, so its
        // crop is history, not a live edit — don't badge it.
        if crsIsAlreadyApplied(in: dict) {
            return false
        }
        // crsHasCrop alone is not enough: opening the crop tool persists it with a
        // full-frame 0,0,1,1 rect. Only a non-identity rect or angle is a real crop.
        let top = parseDoubleValue(dict[MetadataDictKey.crsCropTop]) ?? 0
        let left = parseDoubleValue(dict[MetadataDictKey.crsCropLeft]) ?? 0
        let bottom = parseDoubleValue(dict[MetadataDictKey.crsCropBottom]) ?? 1
        let right = parseDoubleValue(dict[MetadataDictKey.crsCropRight]) ?? 1
        let angle = parseDoubleValue(dict[MetadataDictKey.crsCropAngle]) ?? 0
        let epsilon = 0.0001

        return abs(top) > epsilon
            || abs(left) > epsilon
            || abs(bottom - 1) > epsilon
            || abs(right - 1) > epsilon
            || abs(angle) > epsilon
    }

    private func cropRegion(in dict: [String: Any], exifOrientation: Int = 1) -> ThumbnailCropRegion? {
        guard hasCropEdits(in: dict) else { return nil }
        // crs values are Adobe's un-rotated-frame corner encoding; decode to the
        // app's upright rect before the orientation transform (identity at angle 0).
        let sensorCrop = CameraRawCrop(
            top: parseDoubleValue(dict[MetadataDictKey.crsCropTop]),
            left: parseDoubleValue(dict[MetadataDictKey.crsCropLeft]),
            bottom: parseDoubleValue(dict[MetadataDictKey.crsCropBottom]),
            right: parseDoubleValue(dict[MetadataDictKey.crsCropRight]),
            angle: parseDoubleValue(dict[MetadataDictKey.crsCropAngle]),
            hasCrop: parseBoolValue(dict[MetadataDictKey.crsHasCrop])
        ).decodedFromACR(aspect: metadataDictPixelAspect(dict))
        let displayCrop = sensorCrop.transformedForDisplay(orientation: exifOrientation)
        let top = displayCrop.top ?? 0
        let left = displayCrop.left ?? 0
        let bottom = displayCrop.bottom ?? 1
        let right = displayCrop.right ?? 1
        let angle = displayCrop.angle ?? 0
        let region = ThumbnailCropRegion(top: top, left: left, bottom: bottom, right: right, angle: angle).clamped
        guard region.right > region.left, region.bottom > region.top else { return nil }
        return region
    }

    private func parseBoolValue(_ value: Any?) -> Bool? {
        if let boolValue = value as? Bool { return boolValue }
        if let intValue = value as? Int { return intValue != 0 }
        if let number = value as? NSNumber { return number.intValue != 0 }
        if let stringValue = value as? String {
            let normalized = stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["1", "true", "yes"].contains(normalized) { return true }
            if ["0", "false", "no"].contains(normalized) { return false }
        }
        return nil
    }

    // parseDoubleValue / parseIntValue intentionally live in IPTCMetadataParsing.swift
    // (top-level `nonisolated` helpers). They used to be duplicated here, but the local
    // parseIntValue did an unguarded `Int(doubleValue)` that traps on a crafted/corrupt
    // metadata value of inf/nan/overflow — the shared version routes through `safeInt`.
    // Don't reintroduce private copies; reuse the shared, hardened helpers.

    private func parseToneCurve(_ value: Any?) -> [ToneCurvePoint]? {
        guard let array = value as? [String], array.count >= 2 else { return nil }
        let points = array.compactMap { str -> ToneCurvePoint? in
            let parts = str.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2,
                  let x = Double(parts[0]),
                  let y = Double(parts[1]) else { return nil }
            return ToneCurvePoint(acr255: x, y)
        }
        return points.isIdentityToneCurve ? nil : points
    }

    private func cameraRawSettings(in dict: [String: Any]) -> CameraRawSettings? {
        // crs values are Adobe's un-rotated-frame corner encoding; decode to the
        // app's upright-rect convention (identity at angle 0).
        let crop = CameraRawCrop(
            top: parseDoubleValue(dict[MetadataDictKey.crsCropTop]),
            left: parseDoubleValue(dict[MetadataDictKey.crsCropLeft]),
            bottom: parseDoubleValue(dict[MetadataDictKey.crsCropBottom]),
            right: parseDoubleValue(dict[MetadataDictKey.crsCropRight]),
            angle: parseDoubleValue(dict[MetadataDictKey.crsCropAngle]),
            hasCrop: parseBoolValue(dict[MetadataDictKey.crsHasCrop])
        ).decodedFromACR(aspect: metadataDictPixelAspect(dict))
        let cropValue = crop.isEmpty ? nil : crop

        let tcMaster = parseToneCurve(dict[MetadataDictKey.crsToneCurvePV2012])
        let tcRed = parseToneCurve(dict[MetadataDictKey.crsToneCurvePV2012Red])
        let tcGreen = parseToneCurve(dict[MetadataDictKey.crsToneCurvePV2012Green])
        let tcBlue = parseToneCurve(dict[MetadataDictKey.crsToneCurvePV2012Blue])
        let toneCurve: ToneCurve? = {
            let tc = ToneCurve(master: tcMaster, red: tcRed, green: tcGreen, blue: tcBlue)
            return tc.isEmpty ? nil : tc
        }()

        let settings = CameraRawSettings(
            version: dict[MetadataDictKey.crsVersion] as? String,
            processVersion: dict[MetadataDictKey.crsProcessVersion] as? String,
            whiteBalance: dict[MetadataDictKey.crsWhiteBalance] as? String,
            temperature: parseIntValue(dict[MetadataDictKey.crsTemperature]),
            tint: parseIntValue(dict[MetadataDictKey.crsTint]),
            incrementalTemperature: parseIntValue(dict[MetadataDictKey.crsIncrementalTemperature]),
            incrementalTint: parseIntValue(dict[MetadataDictKey.crsIncrementalTint]),
            exposure2012: parseDoubleValue(dict[MetadataDictKey.crsExposure2012]),
            contrast2012: parseIntValue(dict[MetadataDictKey.crsContrast2012]),
            highlights2012: parseIntValue(dict[MetadataDictKey.crsHighlights2012]),
            shadows2012: parseIntValue(dict[MetadataDictKey.crsShadows2012]),
            whites2012: parseIntValue(dict[MetadataDictKey.crsWhites2012]),
            blacks2012: parseIntValue(dict[MetadataDictKey.crsBlacks2012]),
            saturation: parseIntValue(dict[MetadataDictKey.crsSaturation]),
            vibrance: parseIntValue(dict[MetadataDictKey.crsVibrance]),
            globalDensity: parseIntValue(dict[MetadataDictKey.globalDensity]),
            sharpness: parseIntValue(dict[MetadataDictKey.crsSharpness]),
            clarity2012: parseIntValue(dict[MetadataDictKey.crsClarity2012]),
            dehaze: parseIntValue(dict[MetadataDictKey.crsDehaze]),
            hasSettings: parseBoolValue(dict[MetadataDictKey.crsHasSettings]),
            crop: cropValue,
            hdrEditMode: parseIntValue(dict[MetadataDictKey.crsHDREditMode]),
            hdrMaxValue: dict[MetadataDictKey.crsHDRMaxValue] as? String,
            sdrBrightness: parseIntValue(dict[MetadataDictKey.crsSDRBrightness]),
            sdrContrast: parseIntValue(dict[MetadataDictKey.crsSDRContrast]),
            sdrClarity: parseIntValue(dict[MetadataDictKey.crsSDRClarity]),
            sdrHighlights: parseIntValue(dict[MetadataDictKey.crsSDRHighlights]),
            sdrShadows: parseIntValue(dict[MetadataDictKey.crsSDRShadows]),
            sdrWhites: parseIntValue(dict[MetadataDictKey.crsSDRWhites]),
            sdrBlend: parseIntValue(dict[MetadataDictKey.crsSDRBlend]),
            toneCurve: toneCurve,
            hslAdjustments: decodeHSLAdjustments { parseIntValue(dict[$0]) }
        )
        // A crs block marked AlreadyApplied="True" is baked into the pixels (our own
        // export, or an ACR-rendered-from-RAW JPEG) — treat it as unedited so the
        // settings aren't applied a second time on top of the already-baked render.
        if crsIsAlreadyApplied(in: dict) { return nil }
        return settings.isEmpty ? nil : settings
    }

    // MARK: - Arrow Key Navigation

    @discardableResult
    private func navigateFullScreenFaceSequence(step: Int) -> Bool {
        guard isFullScreen,
              let navigationItems = fullScreenFaceContext?.navigationItems,
              !navigationItems.isEmpty else {
            return false
        }

        let anchor = selectedImageIDs.first ?? lastClickedImageURL
        guard let anchorURL = anchor,
              let currentIndex = navigationItems.firstIndex(where: { $0.imageURL == anchorURL }) else {
            guard let firstItem = navigationItems.first else { return false }
            selectedImageIDs = [firstItem.imageURL]
            lastClickedImageURL = firstItem.imageURL
            if var faceContext = fullScreenFaceContext {
                faceContext.highlightedFaceID = firstItem.faceID
                fullScreenFaceContext = faceContext
                faceContext.onNavigateToFace?(firstItem.faceID)
            }
            return true
        }

        let targetIndex = max(0, min(currentIndex + step, navigationItems.count - 1))
        let targetItem = navigationItems[targetIndex]
        selectedImageIDs = [targetItem.imageURL]
        lastClickedImageURL = targetItem.imageURL
        if var faceContext = fullScreenFaceContext {
            faceContext.highlightedFaceID = targetItem.faceID
            fullScreenFaceContext = faceContext
            faceContext.onNavigateToFace?(targetItem.faceID)
        }
        return true
    }

    // MARK: - Compute Selection (without mutating @Observable state)

    /// Compute the next selection without mutating state. Returns nil if handled by full-screen face navigation.
    func computeNextSelection(extending: Bool = false) -> (ids: Set<URL>, active: URL?)? {
        if navigateFullScreenFaceSequence(step: 1) { return nil }
        guard !visibleImages.isEmpty else { return nil }
        let anchor = lastClickedImageURL ?? selectedImageIDs.first
        guard let anchorURL = anchor,
              let currentIndex = urlToVisibleIndex[anchorURL] else {
            guard let first = visibleImages.first else { return nil }
            return (ids: [first.url], active: first.url)
        }
        let nextIndex = min(currentIndex + 1, visibleImages.count - 1)
        let nextURL = visibleImages[nextIndex].url
        if extending {
            var updated = selectedImageIDs
            updated.insert(nextURL)
            return (ids: updated, active: nextURL)
        } else {
            return (ids: [nextURL], active: nextURL)
        }
    }

    /// Compute the previous selection without mutating state. Returns nil if handled by full-screen face navigation.
    func computePreviousSelection(extending: Bool = false) -> (ids: Set<URL>, active: URL?)? {
        if navigateFullScreenFaceSequence(step: -1) { return nil }
        guard !visibleImages.isEmpty else { return nil }
        let anchor = lastClickedImageURL ?? selectedImageIDs.first
        guard let anchorURL = anchor,
              let currentIndex = urlToVisibleIndex[anchorURL] else {
            guard let first = visibleImages.first else { return nil }
            return (ids: [first.url], active: first.url)
        }
        let prevIndex = max(currentIndex - 1, 0)
        let prevURL = visibleImages[prevIndex].url
        if extending {
            var updated = selectedImageIDs
            updated.insert(prevURL)
            return (ids: updated, active: prevURL)
        } else {
            return (ids: [prevURL], active: prevURL)
        }
    }

    /// Compute down selection without mutating state.
    func computeDownSelection(columns: Int, extending: Bool = false) -> (ids: Set<URL>, active: URL?)? {
        guard !visibleImages.isEmpty, columns > 0 else { return nil }
        let anchor = lastClickedImageURL ?? selectedImageIDs.first
        guard let anchorURL = anchor,
              let currentIndex = urlToVisibleIndex[anchorURL] else {
            guard let first = visibleImages.first else { return nil }
            return (ids: [first.url], active: first.url)
        }
        let targetIndex = min(currentIndex + columns, visibleImages.count - 1)
        let targetURL = visibleImages[targetIndex].url
        if extending {
            var updated = selectedImageIDs
            if targetIndex > currentIndex {
                for i in (currentIndex + 1)...targetIndex {
                    updated.insert(visibleImages[i].url)
                }
            }
            return (ids: updated, active: targetURL)
        } else {
            return (ids: [targetURL], active: targetURL)
        }
    }

    /// Compute up selection without mutating state.
    func computeUpSelection(columns: Int, extending: Bool = false) -> (ids: Set<URL>, active: URL?)? {
        guard !visibleImages.isEmpty, columns > 0 else { return nil }
        let anchor = lastClickedImageURL ?? selectedImageIDs.first
        guard let anchorURL = anchor,
              let currentIndex = urlToVisibleIndex[anchorURL] else {
            guard let first = visibleImages.first else { return nil }
            return (ids: [first.url], active: first.url)
        }
        let targetIndex = max(currentIndex - columns, 0)
        let targetURL = visibleImages[targetIndex].url
        if extending {
            var updated = selectedImageIDs
            if targetIndex < currentIndex {
                for i in targetIndex..<currentIndex {
                    updated.insert(visibleImages[i].url)
                }
            }
            return (ids: updated, active: targetURL)
        } else {
            return (ids: [targetURL], active: targetURL)
        }
    }

    /// Compute select-all without mutating state.
    func computeSelectAll() -> (ids: Set<URL>, active: URL?)? {
        guard !visibleImages.isEmpty else { return nil }
        let active = lastClickedImageURL ?? visibleImages.first?.url
        return (ids: Set(visibleImages.map(\.url)), active: active)
    }

    /// Apply a precomputed selection to @Observable state.
    func applySelection(ids: Set<URL>, active: URL?) {
        selectedImageIDs = ids
        lastClickedImageURL = active
    }

    // MARK: - Selection Navigation (convenience, used by menu notification handlers)

    func selectNext(extending: Bool = false) {
        guard let sel = computeNextSelection(extending: extending) else { return }
        applySelection(ids: sel.ids, active: sel.active)
    }

    func selectPrevious(extending: Bool = false) {
        guard let sel = computePreviousSelection(extending: extending) else { return }
        applySelection(ids: sel.ids, active: sel.active)
    }

    /// Navigate down one row in a grid layout
    func selectDown(columns: Int, extending: Bool = false) {
        guard let sel = computeDownSelection(columns: columns, extending: extending) else { return }
        applySelection(ids: sel.ids, active: sel.active)
    }

    /// Navigate up one row in a grid layout
    func selectUp(columns: Int, extending: Bool = false) {
        guard let sel = computeUpSelection(columns: columns, extending: extending) else { return }
        applySelection(ids: sel.ids, active: sel.active)
    }

    /// Select all images in the current folder
    func selectAll() {
        guard let sel = computeSelectAll() else { return }
        applySelection(ids: sel.ids, active: sel.active)
    }

    // MARK: - Rating & Labels

    func setRating(_ rating: StarRating) {
        applyMetadataField(
            updateImage: { $0.starRating = rating },
            affectsSortKey: sortOrder == .rating,
            affectsFilterKey: minimumStarRating != .none,
            applySidecar: { url, writeXmp, pending in
                await self.applyFieldToSidecar(
                    url: url, writeXmpSidecar: writeXmp, pendingChanges: pending,
                    fieldName: "Rating",
                    getOld: { $0.rating.map(String.init) },
                    applyNew: { metadata in
                        metadata.rating = rating == .none ? nil : rating.rawValue
                        return metadata.rating.map(String.init)
                    }
                )
            },
            writeToFile: { try await self.writeEngine.writeRating(rating, to: $0) },
            fieldDescription: "rating"
        )
    }

    func setLabel(_ label: ColorLabel) {
        applyMetadataField(
            updateImage: { $0.colorLabel = label },
            affectsSortKey: sortOrder == .label,
            affectsFilterKey: !selectedColorLabels.isEmpty,
            applySidecar: { url, writeXmp, pending in
                await self.applyFieldToSidecar(
                    url: url, writeXmpSidecar: writeXmp, pendingChanges: pending,
                    fieldName: "Label",
                    getOld: { $0.label },
                    applyNew: { metadata in
                        metadata.label = label.xmpLabelValue
                        return metadata.label
                    }
                )
            },
            writeToFile: { try await self.writeEngine.writeLabel(label, to: $0) },
            fieldDescription: "label"
        )
    }

    /// Move all images currently labeled `.trash` to a sibling `.Rejected/`
    /// subfolder, along with their JSON and XMP sidecars. Reloads the folder
    /// when finished so the grid reflects the move. Returns the count moved.
    @discardableResult
    func moveRejectedToFolder() -> Int {
        guard let folderURL = currentFolderURL else { return 0 }
        let rejectedURLs = visibleImages.filter { $0.colorLabel == .trash }.map(\.url)
        guard !rejectedURLs.isEmpty else { return 0 }

        let result = RejectMoveService.moveRejected(urls: rejectedURLs, in: folderURL)
        if !result.failedFiles.isEmpty {
            errorMessage = "Failed to move \(result.failedFiles.count) rejected file(s) to \(RejectMoveService.rejectedFolderName)/."
        }

        // Reload current folder so the grid drops the moved files.
        loadFolder(url: folderURL, addToOpenFolders: false)
        return result.movedFiles.count
    }

    func rotateClockwise() {
        guard !selectedImageIDs.isEmpty else { return }
        var newOrientations: [URL: Int] = [:]
        for image in selectedImages {
            newOrientations[image.url] = ImageFile.orientationAfterClockwiseRotation(image.exifOrientation)
            logger.info("[\(image.url.lastPathComponent, privacy: .public)] rotateClockwise \(image.exifOrientation) → \(newOrientations[image.url] ?? -1)")
        }
        applyMetadataField(
            updateImage: { image in
                image.exifOrientation = newOrientations[image.url] ?? image.exifOrientation
            },
            affectsSortKey: false,
            affectsFilterKey: false,
            applySidecar: { url, writeXmp, pending in
                await self.applyFieldToSidecar(
                    url: url, writeXmpSidecar: writeXmp, pendingChanges: pending,
                    fieldName: "Orientation",
                    getOld: { $0.exifOrientation.map(String.init) },
                    applyNew: { metadata in
                        metadata.exifOrientation = newOrientations[url]
                        return metadata.exifOrientation.map(String.init)
                    }
                )
            },
            writeToFile: { urls in
                var byOrientation: [Int: [URL]] = [:]
                for url in urls {
                    let orientation = newOrientations[url] ?? 1
                    byOrientation[orientation, default: []].append(url)
                }
                for (orientation, batchURLs) in byOrientation {
                    try await self.writeEngine.writeOrientation(orientation, to: batchURLs)
                }
            },
            fieldDescription: "orientation"
        )
        for url in selectedImages.map(\.url) {
            thumbnailService.rotateThumbnailInCache(for: url, clockwise: true)
            // Cached full-screen decodes were corrected for the OLD orientation —
            // without this, the spacebar preview keeps showing the unrotated image.
            fullScreenImageCache.invalidateImage(for: url)
        }
    }

    func rotateCounterclockwise() {
        guard !selectedImageIDs.isEmpty else { return }
        var newOrientations: [URL: Int] = [:]
        for image in selectedImages {
            newOrientations[image.url] = ImageFile.orientationAfterCounterclockwiseRotation(image.exifOrientation)
            logger.info("[\(image.url.lastPathComponent, privacy: .public)] rotateCounterclockwise \(image.exifOrientation) → \(newOrientations[image.url] ?? -1)")
        }
        applyMetadataField(
            updateImage: { image in
                image.exifOrientation = newOrientations[image.url] ?? image.exifOrientation
            },
            affectsSortKey: false,
            affectsFilterKey: false,
            applySidecar: { url, writeXmp, pending in
                await self.applyFieldToSidecar(
                    url: url, writeXmpSidecar: writeXmp, pendingChanges: pending,
                    fieldName: "Orientation",
                    getOld: { $0.exifOrientation.map(String.init) },
                    applyNew: { metadata in
                        metadata.exifOrientation = newOrientations[url]
                        return metadata.exifOrientation.map(String.init)
                    }
                )
            },
            writeToFile: { urls in
                var byOrientation: [Int: [URL]] = [:]
                for url in urls {
                    let orientation = newOrientations[url] ?? 1
                    byOrientation[orientation, default: []].append(url)
                }
                for (orientation, batchURLs) in byOrientation {
                    try await self.writeEngine.writeOrientation(orientation, to: batchURLs)
                }
            },
            fieldDescription: "orientation"
        )
        for url in selectedImages.map(\.url) {
            thumbnailService.rotateThumbnailInCache(for: url, clockwise: false)
            // See rotateClockwise — stale full-screen decodes carry the old orientation.
            fullScreenImageCache.invalidateImage(for: url)
        }
    }

    private func applyMetadataField(
        updateImage: (inout ImageFile) -> Void,
        affectsSortKey: Bool,
        affectsFilterKey: Bool,
        applySidecar: @escaping (URL, Bool, Bool) async -> Void,
        writeToFile: @escaping ([URL]) async throws -> Void,
        fieldDescription: String
    ) {
        guard !selectedImageIDs.isEmpty else { return }
        let urls = selectedImages.map(\.url)
        let c2paByURL = Dictionary(uniqueKeysWithValues: selectedImages.map { ($0.url, $0.hasC2PA) })

        // Phase 1: In-place mutation — skip the didSet cascade since URLs don't change
        suppressImagesCascade = true
        defer { suppressImagesCascade = false }
        for url in selectedImageIDs {
            guard let index = urlToImageIndex[url] else { continue }
            updateImage(&images[index])
        }

        // Phase 2: Propagate changes to sorted/visible caches
        if affectsSortKey {
            rebuildSortedCache()
        } else {
            for url in selectedImageIDs {
                guard let imageIdx = urlToImageIndex[url],
                      let sortedIdx = urlToSortedIndex[url] else { continue }
                sortedImages[sortedIdx] = images[imageIdx]
            }

            if affectsFilterKey || isFilteringActive {
                let filterContext = makeImageFilterContext()
                var needsFullRebuild = false
                for url in selectedImageIDs {
                    guard let imageIdx = urlToImageIndex[url] else { continue }
                    let updatedImage = images[imageIdx]
                    let passes = imagePassesFilter(updatedImage, context: filterContext)
                    if let visibleIdx = urlToVisibleIndex[url] {
                        if passes {
                            visibleImages[visibleIdx] = updatedImage
                        } else {
                            needsFullRebuild = true
                            break
                        }
                    } else if passes {
                        needsFullRebuild = true
                        break
                    }
                }
                if needsFullRebuild {
                    rebuildVisibleCache()
                } else {
                    rebuildSelectedCache()
                }
            } else {
                for url in selectedImageIDs {
                    guard let imageIdx = urlToImageIndex[url],
                          let visibleIdx = urlToVisibleIndex[url] else { continue }
                    visibleImages[visibleIdx] = images[imageIdx]
                }
                rebuildSelectedCache()
            }
        }

        metadataWriteTask?.cancel()
        metadataWriteTask = Task {
            var writeToFileWithSidecar: [URL] = []
            var writeToSidecar: [URL] = []
            var writeToXmp: [URL] = []

            for url in urls {
                let hasC2PA = c2paByURL[url] ?? false
                let mode = MetadataWriteMode.current(forC2PA: hasC2PA, isRaw: SupportedImageFormats.isRaw(url: url))

                switch mode {
                case .historyOnly:
                    writeToSidecar.append(url)
                case .writeToFileAndXMPSidecar:
                    // Dual write: file (with history) + .xmp sidecar.
                    writeToFileWithSidecar.append(url)
                    writeToXmp.append(url)
                case .writeToXMPSidecar:
                    writeToXmp.append(url)
                case .writeToFile:
                    writeToFileWithSidecar.append(url)
                }
            }

            for url in writeToSidecar {
                await applySidecar(url, false, true)
            }
            for url in writeToXmp {
                await applySidecar(url, true, false)
            }
            for url in writeToFileWithSidecar {
                // PM-style embed: the file is the record, but an .xmp already on disk
                // must mirror the new value or its stale copy shadows the file on
                // read/export. (Dual-write URLs were already handled above; the
                // unchanged-value guard makes this second pass a no-op for them.)
                await applySidecar(url, xmpSidecarService.sidecarExists(for: url), false)
            }

            if metadataReadService.isAvailable, !writeToFileWithSidecar.isEmpty {
                do {
                    try await writeToFile(writeToFileWithSidecar)
                } catch {
                    self.errorMessage = "Failed to write \(fieldDescription): \(error.localizedDescription)"
                }
            }

            self.refreshPendingStatusBatch(for: urls)
        }
    }

    private func applyPendingSidecarOverrides(for url: URL, index: Int, cachedSidecar: MetadataSidecar? = nil) {
        applyPendingSidecarOverrides(to: &images, for: url, index: index, cachedSidecar: cachedSidecar)
    }

    private func applyPendingSidecarOverrides(to array: inout [ImageFile], for url: URL, index: Int, cachedSidecar: MetadataSidecar? = nil) {
        let sidecar: MetadataSidecar
        if let cached = cachedSidecar {
            sidecar = cached
        } else if let folderURL = currentFolderURL,
                  let loaded = sidecarService.loadSidecar(for: url, in: folderURL) {
            sidecar = loaded
        } else {
            return
        }
        guard sidecar.pendingChanges else { return }

        if let snapshot = sidecar.imageMetadataSnapshot {
            if sidecar.metadata.rating != snapshot.rating {
                let ratingValue = sidecar.metadata.rating ?? 0
                array[index].starRating = StarRating(rawValue: ratingValue) ?? .none
            }
            if sidecar.metadata.label != snapshot.label {
                array[index].colorLabel = ColorLabel.fromMetadataLabel(sidecar.metadata.label)
            }
            // cameraRaw is sourced from XMP only, not from JSON sidecar
        } else {
            if let ratingValue = sidecar.metadata.rating {
                array[index].starRating = StarRating(rawValue: ratingValue) ?? .none
            }
            array[index].colorLabel = ColorLabel.fromMetadataLabel(sidecar.metadata.label)
        }
    }

    /// Apply cameraRaw and crop state from XMP during initial folder load.
    /// Camera raw is no longer stored in JSON sidecars — this is now a no-op
    /// until metadata is read (which populates cameraRaw from XMP).
    private func applySidecarCropAndDevelopState(to imageFile: inout ImageFile, sidecar: MetadataSidecar) {
        // Camera raw data is sourced from XMP only, not from JSON sidecar.
        // Crop/develop state will be applied when metadata loads.
    }

    private func applySidecarCropState(to imageFile: inout ImageFile, cameraRaw: CameraRawSettings?) {
        if let cameraRaw, let crop = cameraRaw.crop, crop.isEffectiveCrop {
            imageFile.hasCropEdits = true
            imageFile.hasDevelopEdits = true
            let displayCrop = crop.transformedForDisplay(orientation: imageFile.exifOrientation)
            let top = displayCrop.top ?? 0
            let left = displayCrop.left ?? 0
            let bottom = displayCrop.bottom ?? 1
            let right = displayCrop.right ?? 1
            let angle = displayCrop.angle ?? 0
            let region = ThumbnailCropRegion(top: top, left: left, bottom: bottom, right: right, angle: angle).clamped
            imageFile.cropRegion = (region.right > region.left && region.bottom > region.top) ? region : nil
        } else {
            imageFile.hasCropEdits = false
            imageFile.cropRegion = nil
            if let cameraRaw, cameraRaw.hasEffectiveEdits {
                imageFile.hasDevelopEdits = true
            }
        }
    }

    private func applyFieldToSidecar(
        url: URL,
        writeXmpSidecar: Bool,
        pendingChanges: Bool,
        fieldName: String,
        getOld: (IPTCMetadata) -> String?,
        applyNew: (inout IPTCMetadata) -> String?
    ) async {
        guard let folderURL = currentFolderURL else { return }

        var metadata = IPTCMetadata()
        var history: [MetadataHistoryEntry] = []
        var snapshot: IPTCMetadata?
        let hadSidecar: Bool

        if let existing = sidecarService.loadSidecar(for: url, in: folderURL) {
            metadata = existing.metadata
            history = existing.history
            history.trimToHistoryLimit()
            snapshot = existing.imageMetadataSnapshot
            hadSidecar = true
        } else {
            hadSidecar = false
        }

        if snapshot == nil {
            snapshot = await loadMetadataSnapshot(for: url)
        }

        if !hadSidecar {
            // Never seed a new record from nothing: a partial sidecar holding only
            // this field would become the authoritative record and mask the file's
            // other descriptive fields on read and export.
            guard let snapshot else {
                errorMessage = "Could not read metadata for \(url.lastPathComponent); \(fieldName) was not written to its sidecar."
                return
            }
            metadata = snapshot
        }

        let oldValue = getOld(metadata)
        let newValue = applyNew(&metadata)

        guard oldValue != newValue else { return }

        history.append(MetadataHistoryEntry(
            timestamp: Date(),
            fieldName: fieldName,
            oldValue: oldValue,
            newValue: newValue
        ))
        history.trimToHistoryLimit()

        let sidecar = MetadataSidecar(
            sourceFile: url.lastPathComponent,
            lastModified: Date(),
            pendingChanges: pendingChanges,
            metadata: metadata,
            imageMetadataSnapshot: pendingChanges ? snapshot : metadata,
            history: history
        )

        do {
            try sidecarService.saveSidecar(sidecar, for: url, in: folderURL)
        } catch {
            errorMessage = "Failed to save metadata sidecar: \(error.localizedDescription)"
        }

        if writeXmpSidecar {
            // `metadata` is sourced from the JSON sidecar (or an embedded snapshot),
            // neither of which carries `cameraRaw` — crs lives only in the .xmp.
            // Use the develop-preserving write so a rating/label/orientation change
            // doesn't strip the user's exposure/crop/mask edits from the sidecar.
            do {
                try xmpSidecarService.saveSidecarPreservingDevelopSettings(metadata: metadata, for: url)
            } catch {
                errorMessage = "Failed to save XMP sidecar: \(error.localizedDescription)"
            }
        }
    }

    private func loadMetadataSnapshot(for url: URL) async -> IPTCMetadata? {
        do {
            var metadata = try await metadataReadService.readFullMetadata(url: url)
            if let xmpMetadata = xmpSidecarService.loadSidecar(for: url) {
                // Record semantics, matching the panel's reference read: a descriptive
                // sidecar IS the record (clears stick — don't reseed cleared fields
                // from embedded); develop-only sidecars overlay additively.
                metadata = xmpMetadata.hasDescriptiveContent
                    ? metadata.replacingDescriptiveFields(from: xmpMetadata)
                    : metadata.merged(preferring: xmpMetadata)
            }
            return metadata
        } catch {
            return nil
        }
    }

    // MARK: - Favorite Folders

    func loadFavorites() {
        guard let data = UserDefaults.standard.data(forKey: favoritesKey),
              let decoded = try? JSONDecoder().decode([FavoriteFolder].self, from: data) else {
            return
        }
        var repaired = decoded
        for index in repaired.indices {
            guard let bookmark = repaired[index].bookmarkData,
                  let resolution = BrowserFolderSecurityScopeStore.shared
                    .resolveAndRetainAccess(bookmark) else { continue }
            repaired[index] = FavoriteFolder(
                id: repaired[index].id,
                url: resolution.url,
                bookmarkData: resolution.bookmarkData
            )
        }
        favoriteFolders = repaired
        if repaired != decoded {
            saveFavorites()
        }
    }

    private func saveFavorites() {
        if let data = try? JSONEncoder().encode(favoriteFolders) {
            UserDefaults.standard.set(data, forKey: favoritesKey)
        }
    }

    func loadFavoriteTopLevelSubfolders() {
        let toLoad = favoriteFolders.map(\.url).filter { subfoldersByOpenFolder[$0] == nil }
        guard !toLoad.isEmpty else { return }
        let service = fileSystemService
        Task.detached(priority: .utility) {
            let results: [(URL, [URL])] = await withTaskGroup(of: (URL, [URL]).self) { group in
                for url in toLoad {
                    group.addTask {
                        let subs = (try? service.listSubfolders(at: url)) ?? []
                        return (url, subs)
                    }
                }
                var out: [(URL, [URL])] = []
                for await pair in group { out.append(pair) }
                return out
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                for (url, subs) in results where self.subfoldersByOpenFolder[url] == nil {
                    self.subfoldersByOpenFolder[url] = subs
                    self.prefetchGrandchildren(of: url)
                }
            }
        }
    }

    @ObservationIgnored private var pendingSubfolderLoads: Set<URL> = []

    /// Lazily loads direct subfolders for a URL if not already cached. The
    /// directory scan runs off MainActor so expanding a folder on a slow or
    /// large volume can't stall the UI; the row shows a spinner until the
    /// cache fills in.
    func ensureSubfoldersLoaded(for url: URL) {
        guard subfoldersByOpenFolder[url] == nil, !pendingSubfolderLoads.contains(url) else { return }
        pendingSubfolderLoads.insert(url)
        let service = fileSystemService
        Task.detached(priority: .userInitiated) {
            let discovered = (try? service.listSubfolders(at: url)) ?? []
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.pendingSubfolderLoads.remove(url)
                if self.subfoldersByOpenFolder[url] == nil {
                    self.subfoldersByOpenFolder[url] = discovered
                }
                self.prefetchGrandchildren(of: url)
            }
        }
    }

    /// For each child of `parentURL` not yet cached, scan its direct subfolders off
    /// MainActor and write the result back, so sidebar chevrons reflect reality at
    /// first render instead of optimistically showing for empty folders.
    private func prefetchGrandchildren(of parentURL: URL) {
        guard let children = subfoldersByOpenFolder[parentURL] else { return }
        let toScan = children.filter { subfoldersByOpenFolder[$0] == nil }
        guard !toScan.isEmpty else { return }
        let service = fileSystemService
        Task.detached(priority: .utility) {
            let results: [(URL, [URL])] = await withTaskGroup(of: (URL, [URL]).self) { group in
                for url in toScan {
                    group.addTask {
                        let subs = (try? service.listSubfolders(at: url)) ?? []
                        return (url, subs)
                    }
                }
                var out: [(URL, [URL])] = []
                for await pair in group { out.append(pair) }
                return out
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                for (url, subs) in results where self.subfoldersByOpenFolder[url] == nil {
                    self.subfoldersByOpenFolder[url] = subs
                }
            }
        }
    }

    func isExpanded(_ url: URL, in tree: SidebarTree) -> Bool {
        switch tree {
        case .favorites(let rootID):
            return expandedFavoriteFolders.contains(
                FavoriteFolderExpansion(rootID: rootID, url: url)
            )
        case .open: return expandedOpenFolders.contains(url)
        }
    }

    /// Toggles expansion of a folder in the sidebar, triggering lazy load on first expand.
    func toggleFolderExpansion(_ url: URL, in tree: SidebarTree) {
        switch tree {
        case .favorites(let rootID):
            let expansion = FavoriteFolderExpansion(rootID: rootID, url: url)
            if expandedFavoriteFolders.contains(expansion) {
                expandedFavoriteFolders.remove(expansion)
            } else {
                expandedFavoriteFolders.insert(expansion)
                ensureSubfoldersLoaded(for: url)
            }
        case .open:
            if expandedOpenFolders.contains(url) {
                expandedOpenFolders.remove(url)
            } else {
                expandedOpenFolders.insert(url)
                ensureSubfoldersLoaded(for: url)
            }
        }
    }

    /// Expands every rendered occurrence of `url` in Favorites. A folder can be
    /// both a favorite root and a descendant of another favorite, so each
    /// occurrence is keyed by its favorite root rather than by URL alone.
    private func expandFavoriteOccurrences(of url: URL) {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        for favorite in favoriteFolders {
            let rootPath = favorite.url.standardizedFileURL.path(percentEncoded: false)
            if path == rootPath || path.hasPrefix(rootPath + "/") {
                expandedFavoriteFolders.insert(
                    FavoriteFolderExpansion(rootID: favorite.id, url: url)
                )
            }
        }
    }

    private func expandFolderInAllSidebarTrees(_ url: URL) {
        expandFavoriteOccurrences(of: url)
        expandedOpenFolders.insert(url)
    }

    /// After an export writes files into a sub-folder, re-scan that sub-folder's
    /// parent so the sidebar tree reflects the (possibly newly created) sub-folder
    /// without a manual close/reopen, then expand the parent so it's visible.
    /// The cached child list is otherwise only built on first expand and never
    /// refreshed, so a folder created on disk by an export would stay hidden.
    func revealExportedSubfolder(_ outputFolderURL: URL) {
        let parentURL = outputFolderURL.deletingLastPathComponent()
        let service = fileSystemService
        Task.detached(priority: .userInitiated) {
            let discovered = (try? service.listSubfolders(at: parentURL)) ?? []
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.subfoldersByOpenFolder[parentURL] = discovered
                self.prefetchGrandchildren(of: parentURL)
                // Expand the parent so the freshly created sub-folder is on screen.
                self.expandFolderInAllSidebarTrees(parentURL)
            }
        }
    }

    /// Re-scans the given folders' direct subfolders off MainActor and writes the
    /// result back, the shared worker behind both the periodic and manual refresh.
    /// Selection (`currentFolderURL`) and expansion (`expandedFavoriteFolders` /
    /// `expandedOpenFolders`) are keyed independently of the child cache, so
    /// replacing a child array never disturbs what's selected or open.
    ///
    /// A failed scan returns nil (distinct from a genuinely empty folder) and is
    /// skipped, so a transient permission/IO hiccup during a background pass can't
    /// blank out a folder that's really still there. When `force` is false the
    /// cache is only reassigned if the contents actually changed, avoiding needless
    /// view churn on the 10s tick.
    private func rescanSubfolders(_ urls: Set<URL>, force: Bool) {
        guard !urls.isEmpty else { return }
        let service = fileSystemService
        Task.detached(priority: .utility) {
            let results: [(URL, [URL]?)] = await withTaskGroup(of: (URL, [URL]?).self) { group in
                for url in urls {
                    group.addTask {
                        let subs = try? service.listSubfolders(at: url)
                        return (url, subs)
                    }
                }
                var out: [(URL, [URL]?)] = []
                for await pair in group { out.append(pair) }
                return out
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                for (url, subs) in results {
                    guard let subs else { continue }
                    if force || self.subfoldersByOpenFolder[url] != subs {
                        self.subfoldersByOpenFolder[url] = subs
                        self.prefetchGrandchildren(of: url)
                    }
                }
            }
        }
    }

    /// Periodic (~10s) sweep that keeps every visible folder's child list in sync
    /// with disk, so subfolders created/renamed/removed externally show up without a
    /// manual reopen. Only scans folders whose children are actually on screen:
    /// favorite roots (always shown) and any expanded folder already in the cache.
    func refreshExpandedSubfolders() {
        var toScan: Set<URL> = Set(favoriteFolders.map(\.url))
        toScan.formUnion(expandedFavoriteFolders.map(\.url))
        toScan.formUnion(expandedOpenFolders)
        let urls = toScan.filter { subfoldersByOpenFolder[$0] != nil }
        rescanSubfolders(Set(urls), force: false)
    }

    /// Manual refresh (right-click → Refresh): force a re-scan of `url` plus any of
    /// its currently-expanded descendants, so a deep refresh updates the whole open
    /// subtree the user is looking at.
    func refreshSubfolders(for url: URL) {
        var toScan: Set<URL> = [url]
        func collectExpanded(_ parent: URL) {
            guard let children = subfoldersByOpenFolder[parent] else { return }
            for child in children
            where expandedFavoriteFolders.contains(where: { $0.url == child })
                || expandedOpenFolders.contains(child) {
                toScan.insert(child)
                collectExpanded(child)
            }
        }
        collectExpanded(url)
        rescanSubfolders(toScan, force: true)
    }

    /// Recursively removes all cached subfolder entries rooted at a URL.
    private func removeSubfolderCacheRecursively(for url: URL) {
        guard let children = subfoldersByOpenFolder.removeValue(forKey: url) else { return }
        expandedFavoriteFolders = Set(
            expandedFavoriteFolders.filter { $0.url != url }
        )
        expandedOpenFolders.remove(url)
        for child in children {
            removeSubfolderCacheRecursively(for: child)
        }
    }

    func addCurrentFolderToFavorites() {
        guard let url = currentFolderURL else { return }
        guard !favoriteFolders.contains(where: { $0.url == url }) else { return }
        let bookmark = BrowserFolderSecurityScopeStore.shared.bookmarkAndRetainAccess(for: url)
        favoriteFolders.append(FavoriteFolder(url: url, bookmarkData: bookmark))
        saveFavorites()
        loadFavoriteTopLevelSubfolders()
    }

    func addFolderToFavorites(_ url: URL) {
        guard !favoriteFolders.contains(where: { $0.url == url }) else { return }
        let bookmark = BrowserFolderSecurityScopeStore.shared.bookmarkAndRetainAccess(for: url)
        favoriteFolders.append(FavoriteFolder(url: url, bookmarkData: bookmark))
        saveFavorites()
        loadFavoriteTopLevelSubfolders()
    }

    func removeFavorite(_ favorite: FavoriteFolder) {
        favoriteFolders.removeAll { $0.id == favorite.id }
        expandedFavoriteFolders = Set(
            expandedFavoriteFolders.filter { $0.rootID != favorite.id }
        )
        saveFavorites()
        let url = favorite.url
        if !openFolders.contains(url) {
            removeSubfolderCacheRecursively(for: url)
        }
    }

    var isCurrentFolderFavorited: Bool {
        guard let url = currentFolderURL else { return false }
        return favoriteFolders.contains { $0.url == url }
    }

    // MARK: - Subfolder Actions

    func openSubfolderAsRoot(_ url: URL) {
        if !openFolders.contains(url) {
            openFolders.append(url)
        }
        loadFolder(url: url)
    }

    /// Add a folder to this view model's Open Folders list (and discover its
    /// subfolders for the tree) WITHOUT loading its images. Used so a folder opened
    /// into another split-view pane still appears in the single, shared sidebar,
    /// which is always backed by the primary pane.
    func registerOpenFolderForSidebar(_ url: URL) {
        guard !favoriteFolders.contains(where: { $0.url == url }),
              !openFolders.contains(url),
              !isSubfolderOfOpenFolder(url) else { return }
        openFolders.append(url)
        guard subfoldersByOpenFolder[url] == nil else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let subs = (try? self.fileSystemService.listSubfolders(at: url)) ?? []
            self.subfoldersByOpenFolder[url] = subs
        }
    }

    var showTrashSubfolderConfirmation = false
    @ObservationIgnored var pendingTrashSubfolderURL: URL?

    func confirmTrashSubfolder(_ url: URL) {
        pendingTrashSubfolderURL = url
        showTrashSubfolderConfirmation = true
    }

    func trashPendingSubfolder() {
        guard let subfolderURL = pendingTrashSubfolderURL else { return }
        pendingTrashSubfolderURL = nil

        do {
            try FileManager.default.trashItem(at: subfolderURL, resultingItemURL: nil)
        } catch {
            errorMessage = "Failed to trash folder: \(error.localizedDescription)"
            return
        }

        // Remove from parent's children list
        for (parentURL, subfolders) in subfoldersByOpenFolder {
            if subfolders.contains(subfolderURL) {
                subfoldersByOpenFolder[parentURL] = subfolders.filter { $0 != subfolderURL }
                break
            }
        }

        // Recursively clean up all cached descendants
        removeSubfolderCacheRecursively(for: subfolderURL)

        // If the trashed folder was the currently viewed folder, navigate away
        if currentFolderURL == subfolderURL {
            if let parent = openFolders.first {
                loadFolder(url: parent)
            } else {
                currentFolderURL = nil
                currentFolderName = nil
                images = []
                selectedImageIDs.removeAll()
            }
        }
    }

    var showRenameSubfolderAlert = false
    var renameSubfolderNewName = ""
    @ObservationIgnored var pendingRenameSubfolderURL: URL?

    func promptRenameSubfolder(_ url: URL) {
        pendingRenameSubfolderURL = url
        renameSubfolderNewName = url.lastPathComponent
        showRenameSubfolderAlert = true
    }

    func renamePendingSubfolder() {
        guard let oldURL = pendingRenameSubfolderURL else { return }
        pendingRenameSubfolderURL = nil
        let trimmed: String
        do {
            trimmed = try SafePathComponent.validate(renameSubfolderNewName)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        guard trimmed != oldURL.lastPathComponent else { return }

        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(trimmed, isDirectory: true)
        guard SafePathComponent.isContained(newURL, in: oldURL.deletingLastPathComponent()) else {
            errorMessage = "Folder name resolves outside its current parent."
            return
        }
        do {
            try FileManager.default.moveItem(at: oldURL, to: newURL)
        } catch {
            errorMessage = "Failed to rename folder: \(error.localizedDescription)"
            return
        }

        // Update parent's children list: replace old URL with new
        for (parentURL, subfolders) in subfoldersByOpenFolder {
            if let idx = subfolders.firstIndex(of: oldURL) {
                var updated = subfolders
                updated[idx] = newURL
                subfoldersByOpenFolder[parentURL] = updated
                break
            }
        }

        let favoriteExpansionRoots = expandedFavoriteFolders.compactMap {
            $0.url == oldURL ? $0.rootID : nil
        }
        let wasExpandedInOpenFolders = expandedOpenFolders.contains(oldURL)

        // Remove all cached descendants of the old path (they have stale URLs)
        removeSubfolderCacheRecursively(for: oldURL)

        // Update expansion state and re-discover children of renamed folder
        for rootID in favoriteExpansionRoots {
            expandedFavoriteFolders.insert(
                FavoriteFolderExpansion(rootID: rootID, url: newURL)
            )
        }
        if wasExpandedInOpenFolders {
            expandedOpenFolders.insert(newURL)
        }
        let migrated = !favoriteExpansionRoots.isEmpty || wasExpandedInOpenFolders
        if migrated {
            ensureSubfoldersLoaded(for: newURL)
        }

        // If the renamed folder was the current folder, reload it
        if currentFolderURL == oldURL {
            loadFolder(url: newURL)
        }
    }

    // MARK: - New Subfolder

    var showNewSubfolderAlert = false
    var newSubfolderName = ""
    @ObservationIgnored var pendingNewSubfolderParentURL: URL?

    func promptNewSubfolder(_ parentURL: URL) {
        pendingNewSubfolderParentURL = parentURL
        newSubfolderName = ""
        showNewSubfolderAlert = true
    }

    func createPendingSubfolder() {
        guard let parentURL = pendingNewSubfolderParentURL else { return }
        pendingNewSubfolderParentURL = nil
        let trimmed: String
        do {
            trimmed = try SafePathComponent.validate(newSubfolderName, label: "Subfolder name")
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let newFolderURL = parentURL.appendingPathComponent(trimmed, isDirectory: true)
        if FileManager.default.fileExists(atPath: newFolderURL.path) {
            errorMessage = "A folder named \"\(trimmed)\" already exists."
            return
        }

        do {
            try FileManager.default.createDirectory(at: newFolderURL, withIntermediateDirectories: false)
        } catch {
            errorMessage = "Failed to create subfolder: \(error.localizedDescription)"
            return
        }

        // Update cache: append and re-sort
        if subfoldersByOpenFolder[parentURL] != nil {
            subfoldersByOpenFolder[parentURL]!.append(newFolderURL)
            subfoldersByOpenFolder[parentURL]!.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        } else {
            ensureSubfoldersLoaded(for: parentURL)
        }
        expandFolderInAllSidebarTrees(parentURL)
    }

    // MARK: - Move Folder

    func moveFolder(_ sourceURL: URL, into destinationURL: URL) {
        let sourcePath = sourceURL.path(percentEncoded: false)
        let destPath = destinationURL.path(percentEncoded: false)

        // Can't move into itself
        guard sourceURL != destinationURL else { return }
        // Can't move into own descendant
        guard !destPath.hasPrefix(sourcePath + "/") else {
            errorMessage = "Cannot move a folder into its own subfolder."
            return
        }
        // Already in that parent — no-op
        guard sourceURL.deletingLastPathComponent().path(percentEncoded: false) != destPath else { return }

        let newURL = destinationURL.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: true)
        if FileManager.default.fileExists(atPath: newURL.path) {
            errorMessage = "A folder named \"\(sourceURL.lastPathComponent)\" already exists in \"\(destinationURL.lastPathComponent)\"."
            return
        }

        Task {
            let moveError: String? = await Task.detached(priority: .userInitiated) {
                do {
                    try FileManager.default.moveItem(at: sourceURL, to: newURL)
                    return nil
                } catch {
                    return "Failed to move folder: \(error.localizedDescription)"
                }
            }.value

            if let moveError {
                errorMessage = moveError
                return
            }

            applyFolderMoveSideEffects(sourceURL: sourceURL, destinationURL: destinationURL, newURL: newURL, sourcePath: sourcePath)
        }
    }

    private func applyFolderMoveSideEffects(sourceURL: URL, destinationURL: URL, newURL: URL, sourcePath: String) {
        // Remove source from its old parent's cache
        for (parentURL, children) in subfoldersByOpenFolder {
            if children.contains(sourceURL) {
                subfoldersByOpenFolder[parentURL] = children.filter { $0 != sourceURL }
                break
            }
        }

        // Add to destination's cache
        if subfoldersByOpenFolder[destinationURL] != nil {
            subfoldersByOpenFolder[destinationURL]!.append(newURL)
            subfoldersByOpenFolder[destinationURL]!.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        } else {
            ensureSubfoldersLoaded(for: destinationURL)
        }

        // Purge stale descendant caches
        removeSubfolderCacheRecursively(for: sourceURL)
        expandFolderInAllSidebarTrees(destinationURL)

        // Update favorites if the moved folder was a favorite root
        if let favIndex = favoriteFolders.firstIndex(where: { $0.url == sourceURL }) {
            favoriteFolders[favIndex].url = newURL
            favoriteFolders[favIndex].name = newURL.lastPathComponent
            favoriteFolders[favIndex].bookmarkData = BrowserFolderSecurityScopeStore.shared
                .bookmarkAndRetainAccess(for: newURL)
            saveFavorites()
        }

        // Update openFolders if the moved folder was an open root
        if let openIndex = openFolders.firstIndex(of: sourceURL) {
            openFolders[openIndex] = newURL
        }

        // Handle current folder
        if currentFolderURL == sourceURL {
            loadFolder(url: newURL)
        } else if let current = currentFolderURL,
                  current.path(percentEncoded: false).hasPrefix(sourcePath + "/") {
            // Current folder was a descendant of the moved folder — its path is now invalid
            let relativeSuffix = current.path(percentEncoded: false).dropFirst(sourcePath.count)
            let newCurrentPath = newURL.path(percentEncoded: false) + relativeSuffix
            loadFolder(url: URL(fileURLWithPath: String(newCurrentPath)))
        }
    }

    // MARK: - Reorder Favorites

    func reorderFavorite(from sourceURL: URL, relativeTo targetURL: URL) {
        guard sourceURL != targetURL else { return }
        guard let sourceIndex = favoriteFolders.firstIndex(where: { $0.url == sourceURL }),
              let targetIndex = favoriteFolders.firstIndex(where: { $0.url == targetURL }) else { return }
        let item = favoriteFolders.remove(at: sourceIndex)
        favoriteFolders.insert(item, at: targetIndex)
        saveFavorites()
    }

    func closeOpenFolder(_ url: URL) {
        let isAlsoFavorite = favoriteFolders.contains { $0.url == url }
        if !isAlsoFavorite {
            removeSubfolderCacheRecursively(for: url)
        }
        openFolders.removeAll { $0 == url }
        folderFilterStates.removeValue(forKey: url)
        // If we closed the current folder (or it was browsing a subfolder of it),
        // switch to another open folder or clear
        let currentPath = (currentFolderURL ?? URL(fileURLWithPath: "/")).path(percentEncoded: false)
        let closedPath = url.path(percentEncoded: false)
        let currentIsDescendant = currentPath.hasPrefix(closedPath + "/")
        if currentFolderURL == url || currentIsDescendant {
            if let nextFolder = openFolders.first {
                loadFolder(url: nextFolder)
            } else {
                currentFolderURL = nil
                currentFolderName = nil
                images = []
                selectedImageIDs.removeAll()
                // Only clear subfolder data for non-favorite entries
                let favoriteURLs = Set(favoriteFolders.map(\.url))
                for key in subfoldersByOpenFolder.keys {
                    if !favoriteURLs.contains(key) {
                        subfoldersByOpenFolder.removeValue(forKey: key)
                    }
                }
            }
        }
    }

    private func isSubfolderOfOpenFolder(_ url: URL) -> Bool {
        let path = url.path(percentEncoded: false)
        for parentURL in openFolders {
            let parentPath = parentURL.path(percentEncoded: false)
            if path.hasPrefix(parentPath + "/") { return true }
        }
        for favorite in favoriteFolders {
            let favPath = favorite.url.path(percentEncoded: false)
            if path.hasPrefix(favPath + "/") { return true }
        }
        return false
    }


    // MARK: - Pending Status

    private func extractPendingFieldNames(from sidecar: MetadataSidecar?) -> [String] {
        guard let sidecar, sidecar.pendingChanges,
              let original = sidecar.imageMetadataSnapshot else {
            return []
        }
        let edited = sidecar.metadata
        var names: [String] = []
        if edited.title != original.title { names.append("Headline") }
        if edited.description != original.description { names.append("Description") }
        if edited.extendedDescription != original.extendedDescription { names.append("Extended Description") }
        if edited.keywords != original.keywords { names.append("Keywords") }
        if edited.personShown != original.personShown { names.append("Person Shown") }
        if edited.rating != original.rating { names.append("Rating") }
        if edited.label != original.label { names.append("Label") }
        if edited.copyright != original.copyright { names.append("Copyright") }
        if edited.jobId != original.jobId { names.append("Job ID") }
        if edited.creator != original.creator { names.append("Creator") }
        if edited.credit != original.credit { names.append("Credit") }
        if edited.city != original.city { names.append("City") }
        if edited.sublocation != original.sublocation { names.append("Sublocation") }
        if edited.provinceState != original.provinceState { names.append("State / Province") }
        if edited.country != original.country { names.append("Country") }
        if edited.event != original.event { names.append("Event") }
        if edited.instructions != original.instructions { names.append("Instructions") }
        if edited.source != original.source { names.append("Source") }
        if edited.digitalSourceType != original.digitalSourceType { names.append("Digital Source Type") }
        if edited.exifOrientation != original.exifOrientation { names.append("Orientation") }
        if edited.latitude != original.latitude || edited.longitude != original.longitude { names.append("GPS Coordinates") }
        if edited.captureDate != original.captureDate { names.append("Capture Date") }
        return names
    }

    func refreshPendingStatus() {
        guard let folderURL = currentFolderURL else { return }
        Task {
            let allSidecars = await sidecarService.loadAllSidecars(in: folderURL)
            guard self.currentFolderURL == folderURL else { return }
            var updated = self.images
            for i in updated.indices {
                if let sidecar = allSidecars[updated[i].url], sidecar.pendingChanges {
                    updated[i].hasPendingMetadataChanges = true
                    updated[i].pendingFieldNames = extractPendingFieldNames(from: sidecar)
                    applyPendingSidecarOverrides(to: &updated, for: updated[i].url, index: i, cachedSidecar: sidecar)
                } else {
                    updated[i].hasPendingMetadataChanges = false
                    updated[i].pendingFieldNames = []
                }
            }
            self.images = updated
        }
    }

    func refreshPendingStatusBatch(for urls: [URL]) {
        guard let folderURL = currentFolderURL, !urls.isEmpty else { return }
        pendingStatusRefreshTask?.cancel()
        pendingStatusRefreshTask = Task { @MainActor [weak self] in
            guard let service = self?.sidecarService else { return }
            let sidecars = await service.loadSidecars(for: urls, in: folderURL)
            guard let self, !Task.isCancelled, self.currentFolderURL == folderURL else { return }
            let urlSet = Set(urls)
            var updated = self.images
            for i in updated.indices where urlSet.contains(updated[i].url) {
                if let sidecar = sidecars[updated[i].url], sidecar.pendingChanges {
                    updated[i].hasPendingMetadataChanges = true
                    updated[i].pendingFieldNames = extractPendingFieldNames(from: sidecar)
                    applyPendingSidecarOverrides(to: &updated, for: updated[i].url, index: i, cachedSidecar: sidecar)
                } else {
                    updated[i].hasPendingMetadataChanges = false
                    updated[i].pendingFieldNames = []
                }
            }
            self.images = updated
        }
    }

    /// Saves an inline edit from Metadata Review as the same pending JSON/XMP sidecar record used
    /// by the metadata panel. Updating the in-memory image first keeps the review list responsive.
    func saveMetadataReviewEdit(_ edited: IPTCMetadata, for url: URL) {
        guard let folderURL = currentFolderURL,
              let index = images.firstIndex(where: { $0.url == url }) else { return }
        let previous = images[index].metadata ?? IPTCMetadata()
        guard edited != previous else { return }

        var updated = images
        updated[index].metadata = edited
        updated[index].keywords = edited.keywords
        updated[index].personShown = edited.personShown
        updated[index].hasPendingMetadataChanges = true
        updated[index].pendingFieldNames = MetadataFieldID.userSelectable.compactMap { field in
            field.textValue(in: previous) != field.textValue(in: edited) ? field.displayName : nil
        }
        images = updated

        let existing = sidecarService.loadSidecar(for: url, in: folderURL)
        var history = existing?.history ?? []
        let now = Date()
        for field in MetadataFieldID.userSelectable {
            let old = field.textValue(in: previous)
            let new = field.textValue(in: edited)
            if old != new {
                history.append(MetadataHistoryEntry(timestamp: now, fieldName: field.displayName, oldValue: old, newValue: new))
            }
        }
        history.trimToHistoryLimit()
        let record = MetadataSidecar(
            sourceFile: url.lastPathComponent,
            lastModified: now,
            pendingChanges: true,
            metadata: edited,
            imageMetadataSnapshot: existing?.imageMetadataSnapshot ?? previous,
            history: history
        )
        do {
            try sidecarService.saveSidecar(record, for: url, in: folderURL)
            try xmpSidecarService.saveSidecarPreservingDevelopSettings(metadata: edited, for: url)
        } catch {
            errorMessage = "Failed to save metadata for \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func updatePendingStatus(for url: URL, hasPending: Bool) {
        if let index = urlToImageIndex[url] {
            images[index].hasPendingMetadataChanges = hasPending
        }
    }

    // MARK: - Delete

    var showDeleteConfirmation = false

    func confirmDeleteSelectedImages() {
        guard !selectedImageIDs.isEmpty else { return }
        showDeleteConfirmation = true
    }

    /// Finds the nearest item to the active image in the pre-deletion filmstrip order. The next
    /// item wins an equal-distance tie, matching the usual “same slot after deletion” behavior.
    nonisolated static func closestSurvivingImageURL(
        in orderedURLs: [URL],
        around anchorURL: URL?,
        deleting deletedURLs: Set<URL>
    ) -> URL? {
        guard !orderedURLs.isEmpty else { return nil }
        guard let anchorURL,
              let anchorIndex = orderedURLs.firstIndex(of: anchorURL) else {
            return orderedURLs.first { !deletedURLs.contains($0) }
        }
        if !deletedURLs.contains(anchorURL) { return anchorURL }

        for distance in 1..<orderedURLs.count {
            let nextIndex = anchorIndex + distance
            if nextIndex < orderedURLs.count {
                let candidate = orderedURLs[nextIndex]
                if !deletedURLs.contains(candidate) { return candidate }
            }

            let previousIndex = anchorIndex - distance
            if previousIndex >= 0 {
                let candidate = orderedURLs[previousIndex]
                if !deletedURLs.contains(candidate) { return candidate }
            }
        }
        return nil
    }

    func deleteSelectedImages() {
        let urlsToDelete = selectedImageIDs
        guard !urlsToDelete.isEmpty else { return }
        let orderedURLs = visibleImages.map(\.url)
        let anchorURL = lastClickedImageURL.flatMap { urlsToDelete.contains($0) ? $0 : nil }
            ?? orderedURLs.first(where: urlsToDelete.contains)
        var deletedURLs: Set<URL> = []
        var failures: [(url: URL, message: String)] = []

        for url in urlsToDelete {
            do {
                try imageTrashHandler.trashItem(at: url)
                deletedURLs.insert(url)
            } catch {
                failures.append((url, error.localizedDescription))
            }
        }

        if !deletedURLs.isEmpty {
            images.removeAll { deletedURLs.contains($0.url) }
            manualOrder.removeAll { deletedURLs.contains($0) }
            pendingMetadataURLs.subtract(deletedURLs)

            // `loadBasicMetadata` deliberately suppresses the normal images.didSet cascade
            // while it awaits each metadata batch. C2PA assets can make that window longer
            // while their embedded manifests are parsed. A deletion during the window must
            // therefore rebuild identity/sort/visible caches explicitly; otherwise the file
            // is in the Trash but its stale thumbnail remains visible and appears undeletable.
            urlToImageIndex = Dictionary(
                uniqueKeysWithValues: images.enumerated().map { ($1.url, $0) }
            )
            rebuildSortedCache(forceSort: true)

            let closestURL = Self.closestSurvivingImageURL(
                in: orderedURLs,
                around: anchorURL,
                deleting: deletedURLs
            )
            selectedImageIDs = closestURL.map { Set([$0]) } ?? []
            lastClickedImageURL = closestURL
            onImagesDeleted?(deletedURLs)

            for url in deletedURLs {
                thumbnailService.invalidateThumbnail(for: url)
                fullScreenImageCache.invalidateImage(for: url)
                Task { await C2PASigningService.invalidateValidationCache(for: url) }
            }
        }

        if let firstFailure = failures.first {
            let suffix = failures.count == 1 ? "" : " and \(failures.count - 1) other file(s)"
            errorMessage = "Couldn’t move \(firstFailure.url.lastPathComponent)\(suffix) to the Trash: \(firstFailure.message)"
        }
    }

    // MARK: - Move to Subfolder

    func promptAddSelectedImagesToSubfolder() {
        guard let folderURL = currentFolderURL else { return }
        guard !selectedImageIDs.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Add to Subfolder"
        alert.informativeText = "Enter a name for the subfolder."

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.placeholderString = "Subfolder name"
        alert.accessoryView = input

        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            presentMoveErrorAlert(message: "Subfolder name can't be empty.")
            return
        }
        if name.rangeOfCharacter(from: CharacterSet(charactersIn: "/:")) != nil {
            presentMoveErrorAlert(message: "Subfolder name can't contain / or : characters.")
            return
        }

        moveSelectedImages(toSubfolderNamed: name, in: folderURL)
    }

    private func moveSelectedImages(toSubfolderNamed name: String, in folderURL: URL) {
        let destinationFolder = folderURL.appendingPathComponent(name)
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: destinationFolder.path) {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: destinationFolder.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                presentMoveErrorAlert(message: "A file named \"\(name)\" already exists in this folder.")
                return
            }
        } else {
            do {
                try fileManager.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
            } catch {
                presentMoveErrorAlert(message: "Failed to create subfolder: \(error.localizedDescription)")
                return
            }
        }

        let urlsToMove = selectedImageIDs
        var moved: Set<URL> = []
        var failures: [String] = []

        for url in urlsToMove {
            let destinationURL = destinationFolder.appendingPathComponent(url.lastPathComponent)
            if fileManager.fileExists(atPath: destinationURL.path) {
                failures.append("\(url.lastPathComponent) already exists in \"\(name)\".")
                continue
            }
            do {
                try fileManager.moveItem(at: url, to: destinationURL)

                let xmpSource = xmpSidecarService.sidecarURL(for: url)
                if fileManager.fileExists(atPath: xmpSource.path) {
                    let xmpDestination = xmpSidecarService.sidecarURL(for: destinationURL)
                    do {
                        try fileManager.moveItem(at: xmpSource, to: xmpDestination)
                    } catch {
                        failures.append("\(url.lastPathComponent) XMP sidecar: \(error.localizedDescription)")
                    }
                }

                do {
                    try sidecarService.moveSidecar(for: url, from: folderURL, to: destinationFolder)
                } catch {
                    failures.append("\(url.lastPathComponent) metadata sidecar: \(error.localizedDescription)")
                }

                moved.insert(url)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if !moved.isEmpty {
            images.removeAll { moved.contains($0.url) }
            manualOrder.removeAll { moved.contains($0) }
            selectedImageIDs.subtract(moved)
            if let last = lastClickedImageURL, moved.contains(last) {
                lastClickedImageURL = nil
            }
            onImagesDeleted?(moved)
        }

        if !failures.isEmpty {
            presentMoveErrorAlert(message: "Failed to move \(failures.count) item(s).")
        }

        var subfolders = subfoldersByOpenFolder[folderURL] ?? []
        if !subfolders.contains(destinationFolder) {
            subfolders.append(destinationFolder)
            subfolders.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            subfoldersByOpenFolder[folderURL] = subfolders
        }
        expandFolderInAllSidebarTrees(folderURL)
    }

    func promptMoveSelectedImagesToFolder() {
        guard let folderURL = currentFolderURL else { return }
        guard !selectedImageIDs.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Choose a destination folder to move \(selectedImageIDs.count) file(s)"
        panel.prompt = "Move Here"

        guard panel.runModal() == .OK, let destinationFolder = panel.url else { return }

        // Don't move to the same folder
        if destinationFolder.standardizedFileURL == folderURL.standardizedFileURL {
            presentMoveErrorAlert(message: "Destination is the same as the current folder.")
            return
        }

        moveImages(Array(selectedImageIDs), into: destinationFolder)
    }

    /// Moves image files to a destination folder along with their XMP and metadata sidecars.
    /// Silently skips files already in the destination (drag-drop onto own folder is a no-op).
    func moveImages(_ urls: [URL], into destinationFolder: URL) {
        guard !urls.isEmpty else { return }

        let destStd = destinationFolder.standardizedFileURL
        let urlsToMove = urls.filter {
            $0.deletingLastPathComponent().standardizedFileURL != destStd
        }
        guard !urlsToMove.isEmpty else { return }

        // Cancel any in-flight thumbnail/prefetch work for these URLs before the
        // move so it doesn't resume against the moved-away path and log a flood
        // of IIOImageSource fileExists==false errors.
        for url in urlsToMove {
            thumbnailService.invalidateThumbnail(for: url)
            fullScreenImageCache.invalidateImage(for: url)
        }

        let xmpService = xmpSidecarService
        let metaService = sidecarService

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Self.performImageMoves(
                    urlsToMove: urlsToMove,
                    destinationFolder: destinationFolder,
                    xmpSidecarService: xmpService,
                    sidecarService: metaService
                )
            }.value

            if !result.moved.isEmpty {
                images.removeAll { result.moved.contains($0.url) }
                manualOrder.removeAll { result.moved.contains($0) }
                selectedImageIDs.subtract(result.moved)
                if let last = lastClickedImageURL, result.moved.contains(last) {
                    lastClickedImageURL = nil
                }
                onImagesDeleted?(result.moved)
            }

            if !result.failures.isEmpty {
                presentMoveErrorAlert(message: "Failed to move \(result.failures.count) item(s):\n" + result.failures.prefix(5).joined(separator: "\n"))
            }
        }
    }

    private nonisolated static func performImageMoves(
        urlsToMove: [URL],
        destinationFolder: URL,
        xmpSidecarService: XMPSidecarService,
        sidecarService: MetadataSidecarService
    ) -> (moved: Set<URL>, failures: [String]) {
        var moved: Set<URL> = []
        var failures: [String] = []
        let fileManager = FileManager.default

        for url in urlsToMove {
            let destinationURL = destinationFolder.appendingPathComponent(url.lastPathComponent)
            if fileManager.fileExists(atPath: destinationURL.path) {
                failures.append("\(url.lastPathComponent) already exists in destination.")
                continue
            }
            do {
                try fileManager.moveItem(at: url, to: destinationURL)

                // Move XMP sidecar
                let xmpSource = xmpSidecarService.sidecarURL(for: url)
                if fileManager.fileExists(atPath: xmpSource.path) {
                    let xmpDestination = xmpSidecarService.sidecarURL(for: destinationURL)
                    do {
                        try fileManager.moveItem(at: xmpSource, to: xmpDestination)
                    } catch {
                        failures.append("\(url.lastPathComponent) XMP sidecar: \(error.localizedDescription)")
                    }
                }

                // Move metadata sidecar (source folder is derived per-URL so this works
                // even when the dragged set spans multiple parent folders).
                do {
                    try sidecarService.moveSidecar(for: url, from: url.deletingLastPathComponent(), to: destinationFolder)
                } catch {
                    failures.append("\(url.lastPathComponent) metadata sidecar: \(error.localizedDescription)")
                }

                moved.insert(url)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        return (moved, failures)
    }

    private func presentMoveErrorAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Move Failed"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Rename

    func renameSelected() {
        guard !selectedImageIDs.isEmpty else { return }
        if selectedImageIDs.count == 1 {
            renameSelectedImage()
        } else {
            batchRenameSelectedImages()
        }
    }

    private func renameSelectedImage() {
        guard let url = selectedImageIDs.first,
              let index = urlToImageIndex[url],
              let folderURL = currentFolderURL else { return }

        let currentName = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension

        let alert = NSAlert()
        alert.messageText = "Rename"
        alert.informativeText = "Enter a new name for the file."

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.stringValue = currentName
        alert.accessoryView = input
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let newName = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != currentName else { return }

        let newURL = url.deletingLastPathComponent()
            .appendingPathComponent(newName)
            .appendingPathExtension(ext)

        guard !FileManager.default.fileExists(atPath: newURL.path) else {
            presentMoveErrorAlert(message: "A file named \"\(newName).\(ext)\" already exists.")
            return
        }

        do {
            try FileManager.default.moveItem(at: url, to: newURL)
        } catch {
            presentMoveErrorAlert(message: "Rename failed: \(error.localizedDescription)")
            return
        }

        // Move XMP sidecar
        var sidecarWarnings: [String] = []
        let xmpSource = xmpSidecarService.sidecarURL(for: url)
        if FileManager.default.fileExists(atPath: xmpSource.path) {
            let xmpDest = xmpSidecarService.sidecarURL(for: newURL)
            do {
                try FileManager.default.moveItem(at: xmpSource, to: xmpDest)
            } catch {
                logger.error("Failed to move XMP sidecar for \(url.lastPathComponent): \(error.localizedDescription)")
                sidecarWarnings.append("XMP sidecar: \(error.localizedDescription)")
            }
        }

        // Rename metadata sidecar to match new filename
        do {
            try sidecarService.renameSidecar(from: url, to: newURL, in: folderURL)
        } catch {
            logger.error("Failed to move metadata sidecar for \(url.lastPathComponent): \(error.localizedDescription)")
            sidecarWarnings.append("Metadata sidecar: \(error.localizedDescription)")
        }

        if !sidecarWarnings.isEmpty {
            let detail = sidecarWarnings.joined(separator: "\n")
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "File renamed, but sidecar files could not be moved"
            alert.informativeText = "The image was renamed successfully, but associated sidecar files failed to follow. Edits stored in these sidecars may not appear for the renamed file.\n\n\(detail)"
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }

        // Update images array
        let newImage = ImageFile(url: newURL, copyingFrom: images[index])
        images[index] = newImage

        // Update selection
        selectedImageIDs = [newURL]
        lastClickedImageURL = newURL

        // Update manual order
        if let manualIndex = manualOrder.firstIndex(of: url) {
            manualOrder[manualIndex] = newURL
        }

        thumbnailService.invalidateThumbnail(for: url)
    }

    private func batchRenameSelectedImages() {
        let alert = NSAlert()
        alert.messageText = "Batch Rename"
        alert.informativeText = "Enter a rename pattern.\nVariables: {original} (original name), {n} (sequence number), {date} (file date YYYYMMDD)"

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.stringValue = "{original}"
        input.placeholderString = "{original}_{n}"
        alert.accessoryView = input
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let pattern = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return }

        guard let folderURL = currentFolderURL else { return }

        // Get selected images in sort order
        let sorted = sortedImages.filter { selectedImageIDs.contains($0.url) }
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd"

        var newSelectionURLs: Set<URL> = []
        var renames: [(oldURL: URL, newURL: URL, index: Int)] = []

        for (seqIndex, image) in sorted.enumerated() {
            guard let index = urlToImageIndex[image.url] else { continue }
            let ext = image.url.pathExtension
            let originalName = image.url.deletingPathExtension().lastPathComponent

            var newName = pattern
            newName = newName.replacingOccurrences(of: "{original}", with: originalName)
            newName = newName.replacingOccurrences(of: "{n}", with: String(seqIndex + 1))
            newName = newName.replacingOccurrences(of: "{date}", with: dateFormatter.string(from: image.dateModified))

            var newURL = image.url.deletingLastPathComponent()
                .appendingPathComponent(newName)
                .appendingPathExtension(ext)

            // Handle name collision
            var counter = 2
            while FileManager.default.fileExists(atPath: newURL.path) && newURL != image.url {
                newURL = image.url.deletingLastPathComponent()
                    .appendingPathComponent("\(newName) \(counter)")
                    .appendingPathExtension(ext)
                counter += 1
            }

            guard newURL != image.url else {
                newSelectionURLs.insert(image.url)
                continue
            }

            renames.append((oldURL: image.url, newURL: newURL, index: index))
        }

        // Execute renames
        var sidecarFailures: [String] = []
        for rename in renames {
            do {
                try FileManager.default.moveItem(at: rename.oldURL, to: rename.newURL)

                let xmpSource = xmpSidecarService.sidecarURL(for: rename.oldURL)
                if FileManager.default.fileExists(atPath: xmpSource.path) {
                    let xmpDest = xmpSidecarService.sidecarURL(for: rename.newURL)
                    do {
                        try FileManager.default.moveItem(at: xmpSource, to: xmpDest)
                    } catch {
                        logger.error("Failed to move XMP sidecar for \(rename.oldURL.lastPathComponent): \(error.localizedDescription)")
                        sidecarFailures.append(rename.oldURL.lastPathComponent)
                    }
                }
                do {
                    try sidecarService.renameSidecar(from: rename.oldURL, to: rename.newURL, in: folderURL)
                } catch {
                    logger.error("Failed to move metadata sidecar for \(rename.oldURL.lastPathComponent): \(error.localizedDescription)")
                    if !sidecarFailures.contains(rename.oldURL.lastPathComponent) {
                        sidecarFailures.append(rename.oldURL.lastPathComponent)
                    }
                }

                let newImage = ImageFile(url: rename.newURL, copyingFrom: images[rename.index])
                images[rename.index] = newImage
                newSelectionURLs.insert(rename.newURL)

                if let manualIndex = manualOrder.firstIndex(of: rename.oldURL) {
                    manualOrder[manualIndex] = rename.newURL
                }

                thumbnailService.invalidateThumbnail(for: rename.oldURL)
            } catch {
                logger.error("Batch rename failed for \(rename.oldURL.lastPathComponent): \(error.localizedDescription)")
                newSelectionURLs.insert(rename.oldURL)
            }
        }

        if !sidecarFailures.isEmpty {
            let fileList = sidecarFailures.prefix(10).joined(separator: ", ")
            let suffix = sidecarFailures.count > 10 ? " and \(sidecarFailures.count - 10) more" : ""
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Some sidecar files could not be moved"
            alert.informativeText = "Images were renamed successfully, but sidecar files for \(sidecarFailures.count) image(s) failed to follow. Edits stored in these sidecars may not appear for the renamed files.\n\n\(fileList)\(suffix)"
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }

        selectedImageIDs = newSelectionURLs
        lastClickedImageURL = newSelectionURLs.first
    }

    // MARK: - Duplicate

    func duplicateSelectedImages() {
        guard let folderURL = currentFolderURL, !selectedImageIDs.isEmpty else { return }

        let sorted = sortedImages.filter { selectedImageIDs.contains($0.url) }
        var newSelectionURLs: Set<URL> = []
        var insertions: [(afterIndex: Int, sourceURL: URL, image: ImageFile)] = []

        for source in sorted {
            guard let sourceIndex = urlToImageIndex[source.url] else { continue }
            let ext = source.url.pathExtension
            let baseName = source.url.deletingPathExtension().lastPathComponent

            // Find available "copy" name
            var copyName = "\(baseName) copy"
            var destURL = folderURL.appendingPathComponent(copyName).appendingPathExtension(ext)
            var counter = 2
            while FileManager.default.fileExists(atPath: destURL.path) {
                copyName = "\(baseName) copy \(counter)"
                destURL = folderURL.appendingPathComponent(copyName).appendingPathExtension(ext)
                counter += 1
            }

            do {
                try FileManager.default.copyItem(at: source.url, to: destURL)

                // Copy metadata sidecar
                if let sidecar = sidecarService.loadSidecar(for: source.url, in: folderURL) {
                    try? sidecarService.saveSidecar(sidecar, for: destURL, in: folderURL)
                }

                let newImage = ImageFile(url: destURL, copyingFrom: source)
                insertions.append((afterIndex: sourceIndex, sourceURL: source.url, image: newImage))
                newSelectionURLs.insert(destURL)
            } catch {
                logger.error("Duplicate failed for \(source.filename): \(error.localizedDescription)")
            }
        }

        // Insert duplicates after their originals (process in reverse to maintain indices)
        for insertion in insertions.reversed() {
            let insertAt = min(insertion.afterIndex + 1, images.count)
            images.insert(insertion.image, at: insertAt)
        }

        // Update manual order — single-pass O(N+M) rebuild instead of O(N*M) repeated scans
        let dupeAfterSource = Dictionary(uniqueKeysWithValues: insertions.map { ($0.sourceURL, $0.image.url) })
        var newManualOrder: [URL] = []
        newManualOrder.reserveCapacity(manualOrder.count + insertions.count)
        for url in manualOrder {
            newManualOrder.append(url)
            if let dupeURL = dupeAfterSource[url] {
                newManualOrder.append(dupeURL)
            }
        }
        // Append any duplicates whose source wasn't in the manual order
        let addedURLs = Set(newManualOrder)
        for insertion in insertions where !addedURLs.contains(insertion.image.url) {
            newManualOrder.append(insertion.image.url)
        }
        manualOrder = newManualOrder

        selectedImageIDs = newSelectionURLs
        lastClickedImageURL = newSelectionURLs.first
    }

    // MARK: - Reset All Edits

    var showResetEditsConfirmation = false

    func confirmResetAllEdits() {
        guard selectedImageIDs.contains(where: { url in
            guard let index = urlToImageIndex[url] else { return false }
            return images[index].hasDevelopEdits || images[index].hasCropEdits
        }) else { return }
        showResetEditsConfirmation = true
    }

    func resetAllEditsOnSelected() {
        let urls = Array(selectedImageIDs)
        guard !urls.isEmpty else { return }

        // Immediately update in-memory state for visual feedback
        for url in urls {
            guard let index = urlToImageIndex[url] else { continue }
            images[index].cameraRawSettings = nil
            images[index].hasDevelopEdits = false
            images[index].hasCropEdits = false
            images[index].cropRegion = nil
            thumbnailService.invalidateThumbnail(for: url)
            // Drop the rendered (edited) full-screen entries too — otherwise the
            // full-screen viewer can serve a cached image still carrying the old
            // edits if it's reopened before the async XMP rewrite lands.
            fullScreenImageCache.invalidateEditedImage(for: url)
        }

        // Clear CRS from the XMP sidecar for EVERY file (not just RAW). Develop edits now
        // persist to the sidecar during editing for non-RAW too (the sidecar is authoritative
        // and wins over embedded crs on load), so a reset that only cleared the embedded file
        // crs would leave the sidecar's develop behind and resurface it on next load.
        // saveCameraRawOnly(nil,…) is a no-op when no sidecar exists, so this is safe for all.
        for url in urls {
            do {
                try xmpSidecarService.saveCameraRawOnly(nil, orientation: nil, for: url)
            } catch {
                logger.error("Failed to clear CRS from XMP sidecar for \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        // Write cleared CRS fields to XMP in the image files
        batchReadTask?.cancel()
        batchReadTask = Task {
            var clearFields: [MetadataFieldKey: String] = [:]
            clearFields[.crsVersion] = ""
            clearFields[.crsProcessVersion] = ""
            clearFields[.crsWhiteBalance] = ""
            clearFields[.crsTemperature] = ""
            clearFields[.crsTint] = ""
            clearFields[.crsIncrementalTemperature] = ""
            clearFields[.crsIncrementalTint] = ""
            clearFields[.crsExposure2012] = ""
            clearFields[.crsContrast2012] = ""
            clearFields[.crsHighlights2012] = ""
            clearFields[.crsShadows2012] = ""
            clearFields[.crsWhites2012] = ""
            clearFields[.crsBlacks2012] = ""
            clearFields[.crsSaturation] = ""
            clearFields[.crsVibrance] = ""
            clearFields[.aaphotoGlobalDensity] = ""
            clearFields[.crsSharpness] = ""
            clearFields[.crsClarity2012] = ""
            clearFields[.crsDehaze] = ""
            clearFields[.crsHasSettings] = "False"
            clearFields[.crsCropTop] = ""
            clearFields[.crsCropLeft] = ""
            clearFields[.crsCropBottom] = ""
            clearFields[.crsCropRight] = ""
            clearFields[.crsCropAngle] = ""
            clearFields[.crsHasCrop] = ""
            clearFields[.crsCropConstrainToWarp] = ""
            clearFields[.crsCropConstrainToUnitSquare] = ""
            clearFields[.crsHDREditMode] = ""
            clearFields[.crsHDRMaxValue] = ""
            clearFields[.crsSDRBrightness] = ""
            clearFields[.crsSDRContrast] = ""
            clearFields[.crsSDRClarity] = ""
            clearFields[.crsSDRHighlights] = ""
            clearFields[.crsSDRShadows] = ""
            clearFields[.crsSDRWhites] = ""
            clearFields[.crsSDRBlend] = ""

            // Replace the whole crs block: clears masks, tone curves, and any
            // settings ACR wrote that the app doesn't manage — a reset means
            // no develop settings remain, whoever authored them.
            let structuredData = StructuredWriteData(masks: [], watermarkLayers: [], replaceCameraRawBlock: true)

            // RAW files keep their CRS in the XMP sidecar (cleared above) — never embed
            // into the RAW container, which corrupts proprietary maker data (e.g. Sony's
            // SR2Private WB block) and breaks the decode. Only write into non-RAW files.
            let fileURLs = urls.filter { !SupportedImageFormats.isRaw(url: $0) }
            guard !fileURLs.isEmpty else { return }
            do {
                try await writeEngine.writeFields(clearFields, to: fileURLs, structuredData: structuredData)
            } catch {
                logger.error("Failed to clear camera raw XMP fields: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Remove All IPTC Metadata

    enum RemoveIPTCMode {
        /// No XMP sidecars found — simple confirmation
        case noSidecars
        /// XMP sidecars exist — let user choose what to remove
        case hasSidecars
    }

    var showRemoveIPTCConfirmation = false
    var showRemoveIPTCSidecarChoice = false
    private(set) var removeIPTCSelectedURLs: [URL] = []

    func confirmRemoveAllIPTC() {
        guard !selectedImageIDs.isEmpty else { return }
        let urls = Array(selectedImageIDs)
        removeIPTCSelectedURLs = urls

        let hasAnySidecar = urls.contains { url in
            let sidecarURL = xmpSidecarService.sidecarURL(for: url)
            return FileManager.default.fileExists(atPath: sidecarURL.path)
        }

        if hasAnySidecar {
            showRemoveIPTCSidecarChoice = true
        } else {
            showRemoveIPTCConfirmation = true
        }
    }

    func removeIPTCFromImageFiles(onComplete: (() -> Void)? = nil) {
        guard let folderURL = currentFolderURL else { return }
        let urls = removeIPTCSelectedURLs

        batchReadTask?.cancel()
        batchReadTask = Task {
            do {
                try await writeEngine.stripIPTCAndXMP(from: urls)
            } catch {
                self.errorMessage = "Failed to remove IPTC metadata: \(error.localizedDescription)"
                return
            }

            for url in urls {
                guard let index = urlToImageIndex[url] else { continue }
                images[index].starRating = .none
                images[index].colorLabel = .none
                images[index].metadata = nil
                images[index].personShown = []
                images[index].hasPendingMetadataChanges = false
                images[index].pendingFieldNames = []

                try? sidecarService.deleteSidecar(for: url, in: folderURL)
            }

            onComplete?()
        }
    }

    func removeIPTCFromXMPSidecars(onComplete: (() -> Void)? = nil) {
        let urls = removeIPTCSelectedURLs

        for url in urls {
            xmpSidecarService.stripIPTCFromSidecar(for: url)
        }

        onComplete?()
    }

    func removeIPTCFromBoth(onComplete: (() -> Void)? = nil) {
        // Strip XMP sidecars synchronously first, then start async image file strip
        let urls = removeIPTCSelectedURLs
        for url in urls {
            xmpSidecarService.stripIPTCFromSidecar(for: url)
        }
        removeIPTCFromImageFiles(onComplete: onComplete)
    }

    // MARK: - Manual Sort

    func initializeManualOrder(from currentSorted: [ImageFile]) {
        manualOrder = currentSorted.map(\.url)
    }

    enum SortOrder: String, CaseIterable {
        case name = "Name"
        case dateModified = "Date Modified"
        case dateAdded = "Date Added"
        case rating = "Rating"
        case label = "Label"
        case fileType = "File Type"
        case manual = "Manual"

        func overlayDescription(reversed: Bool) -> String {
            switch self {
            case .name: return reversed ? "Name Z → A" : "Name A → Z"
            case .dateModified: return reversed ? "Date Modified Oldest First" : "Date Modified Newest First"
            case .dateAdded: return reversed ? "Date Added Oldest First" : "Date Added Newest First"
            case .rating: return reversed ? "Rating Lowest First" : "Rating Highest First"
            case .label: return reversed ? "Label Reversed" : "Label"
            case .fileType: return reversed ? "File Type Z → A" : "File Type A → Z"
            case .manual: return "Manual Order"
            }
        }
    }

    enum PersonShownFilter: String, CaseIterable {
        case any = "Any"
        case missing = "Missing"
        case present = "Present"

        var displayName: String {
            switch self {
            case .any: return "Any"
            case .missing: return "Missing Person Shown"
            case .present: return "Has Person Shown"
            }
        }
    }

    enum EditedFilter: String, CaseIterable {
        case any = "Any"
        case edited = "Edited"
        case unedited = "Unedited"

        var displayName: String {
            switch self {
            case .any: return "Any"
            case .edited: return "Is Edited"
            case .unedited: return "Not Edited"
            }
        }
    }

    enum RequiredMetadataFilter: String, CaseIterable {
        case any = "Any"
        case complete = "Complete"
        case incomplete = "Incomplete"

        var displayName: String {
            switch self {
            case .any: return "Any"
            case .complete: return "Has Required Metadata"
            case .incomplete: return "Missing Required Metadata"
            }
        }
    }

    struct FolderFilterState {
        var minimumStarRating: StarRating = .none
        var selectedColorLabels: Set<ColorLabel> = []
        var personShownFilter: PersonShownFilter = .any
        var editedFilter: EditedFilter = .any
        var requiredMetadataFilter: RequiredMetadataFilter = .any
        var missingFieldFilters: Set<MetadataFieldID> = []
        var searchText: String = ""
    }

    private func saveCurrentFilterState() {
        guard let url = currentFolderURL else { return }
        folderFilterStates[url] = FolderFilterState(
            minimumStarRating: minimumStarRating,
            selectedColorLabels: selectedColorLabels,
            personShownFilter: personShownFilter,
            editedFilter: editedFilter,
            requiredMetadataFilter: requiredMetadataFilter,
            missingFieldFilters: missingFieldFilters,
            searchText: searchText
        )
    }

    private func restoreFilterState(for url: URL) {
        batchUpdate {
            if let saved = folderFilterStates[url] {
                minimumStarRating = saved.minimumStarRating
                selectedColorLabels = saved.selectedColorLabels
                personShownFilter = saved.personShownFilter
                editedFilter = saved.editedFilter
                requiredMetadataFilter = saved.requiredMetadataFilter
                missingFieldFilters = saved.missingFieldFilters
                searchText = saved.searchText
            } else {
                minimumStarRating = .none
                selectedColorLabels = []
                personShownFilter = .any
                editedFilter = .any
                requiredMetadataFilter = .any
                missingFieldFilters = []
                searchText = ""
            }
        }
    }
}
