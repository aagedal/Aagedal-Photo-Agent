import Foundation
import AppKit
import ImageIO
import os

@Observable
final class BrowserViewModel {
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
    var recentFolders: [RecentFolder] = []
    var openFolders: [URL] = []
    var subfoldersByOpenFolder: [URL: [URL]] = [:]
    var expandedFolders: Set<URL> = []
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
    let thumbnailService = ThumbnailService()
    let exifToolService = ExifToolService()
    @ObservationIgnored let fullScreenImageCache = FullScreenImageCache()
    private let sidecarService = MetadataSidecarService()
    private let xmpSidecarService = XMPSidecarService()

    private let logger = Logger(subsystem: "com.aagedal.photo-agent", category: "BrowserViewModel")
    private let perfLog = Logger(subsystem: "com.aagedal.photo-agent", category: "MetadataPerf")
    @ObservationIgnored var onImagesDeleted: ((Set<URL>) -> Void)?
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
    @ObservationIgnored private var pendingMetadataURLs: Set<URL> = []
    @ObservationIgnored private var retinaPreCacheTask: Task<Void, Never>?
    @ObservationIgnored private var suppressImagesCascade = false
    @ObservationIgnored private var pendingMetadataDrainTask: Task<Void, Never>?

    private let favoritesKey = UserDefaultsKeys.favoriteFolders
    private let recentFoldersKey = UserDefaultsKeys.recentFolders

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
    }

    @ObservationIgnored private(set) var selectedImagesCache: [ImageFile] = []

    init() {
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
        rebuildNow()
    }

    private func rebuildVisibleCache() {
        let filtered = applyFilters(to: sortedImages)
        visibleImages = filtered
        urlToVisibleIndex = Dictionary(uniqueKeysWithValues: filtered.enumerated().map { ($1.url, $0) })

        let visibleSet = Set(filtered.map(\.url))
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
        guard fullScreenImageCache.cachedImage(for: url) == nil else { return }

        let imageFile = images[index]
        let screenScale = NSScreen.main?.backingScaleFactor ?? 2.0
        let screenLogicalPx = max(NSScreen.main?.frame.width ?? 3840,
                                   NSScreen.main?.frame.height ?? 2160)
        let screenMaxPx = screenLogicalPx * screenScale
        let cameraRaw = showOriginalThumbnails ? nil : imageFile.cameraRawSettings
        let orientation = imageFile.exifOrientation

        retinaPreCacheTask = Task.detached(priority: .utility) { [weak self] in
            guard let self, !Task.isCancelled else { return }
            var image: CGImage?
            if cameraRaw != nil,
               let ciImage = FullScreenImageCache.loadHDRPreview(from: url, maxPixelSize: screenMaxPx) {
                let processed = CameraRawApproximation.applyWithCrop(to: ciImage, settings: cameraRaw!, exifOrientation: orientation)
                image = CameraRawApproximation.ciContext.createCGImage(
                    processed, from: processed.extent,
                    format: .RGBAh, colorSpace: CameraRawApproximation.workingColorSpace)
            }
            if image == nil {
                guard var loaded = FullScreenImageCache.loadDownsampled(from: url, maxPixelSize: screenMaxPx) else { return }
                if let cameraRaw {
                    loaded = FullScreenImageCache.applyCameraRaw(to: loaded, settings: cameraRaw, exifOrientation: orientation)
                }
                image = loaded
            }
            guard let image, !Task.isCancelled else { return }
            self.fullScreenImageCache.store(image, for: url)
        }
    }

    private func imagePassesFilter(_ image: ImageFile, query: String) -> Bool {
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
        guard !query.isEmpty else { return true }
        if image.filenameLowercased.contains(query) {
            return true
        }
        if image.personShownLowercased.contains(where: { $0.contains(query) }) {
            return true
        }
        if image.keywordsLowercased.contains(where: { $0.contains(query) }) {
            return true
        }
        // Search IPTC metadata fields (title, description, creator, city, country, event)
        if let meta = image.metadata {
            if let title = meta.title, title.localizedCaseInsensitiveContains(query) { return true }
            if let desc = meta.description, desc.localizedCaseInsensitiveContains(query) { return true }
            if let creator = meta.creator, creator.localizedCaseInsensitiveContains(query) { return true }
            if let city = meta.city, city.localizedCaseInsensitiveContains(query) { return true }
            if let country = meta.country, country.localizedCaseInsensitiveContains(query) { return true }
            if let event = meta.event, event.localizedCaseInsensitiveContains(query) { return true }
        }
        return false
    }

    private func applyFilters(to images: [ImageFile]) -> [ImageFile] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return images.filter { imagePassesFilter($0, query: query) }
    }

    func clearFilters() {
        batchUpdate {
            searchText = ""
            minimumStarRating = .none
            selectedColorLabels.removeAll()
            personShownFilter = .any
            editedFilter = .any
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
        // Reset in case the cancelled task's metadata loop left this true,
        // otherwise the images.didSet below won't rebuild urlToImageIndex.
        suppressImagesCascade = false

        saveCurrentFilterState()

        currentFolderURL = url
        currentFolderName = url.lastPathComponent
        trackRecentFolder(url: url)
        isLoading = true
        errorMessage = nil
        images = []
        selectedImageIDs.removeAll()
        lastClickedImageURL = nil
        manualOrder.removeAll()
        thumbnailService.cancelBackgroundGeneration()
        fullScreenImageCache.clearAll()

        restoreFilterState(for: url)

        // Add to open folders if not already there, unless it's a subfolder of an existing open folder
        if addToOpenFolders && !openFolders.contains(url) && !isSubfolderOfOpenFolder(url) {
            openFolders.append(url)
        }

        loadFolderTask = Task {
            do {
                // Phase 1: Scan folder and show grid immediately
                let files = try fileSystemService.scanFolder(at: url, includeAllFiles: showAllFiles)
                guard !Task.isCancelled, self.currentFolderURL == url else { return }
                self.images = files
                self.rebuildNow()
                self.isLoading = false
                self.thumbnailService.startBackgroundGeneration(for: self.visibleImages)

                // Phase 1.5: Read EXIF orientations in background (deferred).
                // Thumbnails don't need this (QL/CGImageSource apply transforms internally).
                // Phase 5 (ExifTool) also sets it; this provides it sooner for full-screen entry.
                var orientedFiles = files
                await self.readOrientationsEagerly(for: &orientedFiles)
                guard !Task.isCancelled, self.currentFolderURL == url else { return }
                let nonDefault = orientedFiles.enumerated().filter { $0.element.exifOrientation != 1 }
                if !nonDefault.isEmpty {
                    self.suppressImagesCascade = true
                    for (index, file) in nonDefault {
                        self.images[index].exifOrientation = file.exifOrientation
                    }
                    self.suppressImagesCascade = false
                }

                // Phase 2: Discover subfolders (non-blocking, after grid is visible)
                let discoveredSubfolders = (try? fileSystemService.listSubfolders(at: url)) ?? []
                guard !Task.isCancelled, self.currentFolderURL == url else { return }
                self.subfoldersByOpenFolder[url] = discoveredSubfolders
                if !discoveredSubfolders.isEmpty {
                    self.expandedFolders.insert(url)
                }

                // Phase 3: Load sidecars and apply pending overrides
                let allSidecars = sidecarService.loadAllSidecars(in: url)
                var updated = files
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

                // Phase 4: Background display preview generation
                self.fullScreenImageCache.startBackgroundPreviewGeneration(
                    for: self.visibleImages.map(\.url),
                    screenMaxPx: 960
                )

                // Phase 5: Load metadata from ExifTool
                await loadBasicMetadata(cachedSidecars: allSidecars)
            } catch {
                guard !Task.isCancelled, self.currentFolderURL == url else { return }
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    func refreshCurrentFolderIfNeeded() {
        guard let folderURL = currentFolderURL else { return }
        guard !isLoading, !isMetadataLoading, !isAutoRefreshing else { return }
        isAutoRefreshing = true

        Task {
            defer { self.isAutoRefreshing = false }

            let scanned: [ImageFile]
            do {
                scanned = try fileSystemService.scanFolder(at: folderURL, includeAllFiles: showAllFiles)
            } catch {
                return
            }

            let existingByURL = Dictionary(uniqueKeysWithValues: images.map { ($0.url, $0) })
            let existingURLs = Set(existingByURL.keys)
            let scannedURLs = Set(scanned.map(\.url))

            var merged: [ImageFile] = []
            merged.reserveCapacity(scanned.count)
            var newURLs: [URL] = []
            var modifiedURLs: [URL] = []

            for item in scanned {
                if let existing = existingByURL[item.url] {
                    let isModified = existing.fileSize != item.fileSize
                        || existing.dateModified != item.dateModified
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
                    if isModified {
                        // File changed on disk — clear stale develop/crop state so
                        // thumbnails reflect the actual file content
                        updated.cameraRawSettings = nil
                        updated.hasDevelopEdits = false
                        updated.hasCropEdits = false
                        updated.cropRegion = nil
                        modifiedURLs.append(item.url)
                    }
                    merged.append(updated)
                } else {
                    var newItem = item
                    if newItem.isImageFile,
                       let source = CGImageSourceCreateWithURL(newItem.url as CFURL, nil),
                       let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                       let orientation = props[kCGImagePropertyOrientation] as? Int {
                        newItem.exifOrientation = orientation
                    }
                    merged.append(newItem)
                    newURLs.append(item.url)
                }
            }

            let removedURLs = existingURLs.subtracting(scannedURLs)
            if newURLs.isEmpty && modifiedURLs.isEmpty && removedURLs.isEmpty {
                return
            }
            guard self.currentFolderURL == folderURL else { return }

            let allSidecars = sidecarService.loadAllSidecars(in: folderURL)
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

            // Invalidate thumbnail cache for modified files so they regenerate
            for url in modifiedURLs {
                thumbnailService.invalidateThumbnail(for: url)
            }

            self.lastRefreshModifiedURLs = Set(modifiedURLs)

            let metadataRefreshURLs = newURLs + modifiedURLs
            if !metadataRefreshURLs.isEmpty {
                pendingMetadataURLs.formUnion(metadataRefreshURLs)
                drainPendingMetadataIfNeeded()
            }
        }
    }

    /// Read EXIF orientation via CGImageSource (metadata-only, ~0.1ms/file).
    /// Called eagerly after folder scan so exifOrientation is correct before
    /// the full ExifTool batch read.
    private func readOrientationsEagerly(for images: inout [ImageFile]) async {
        let indexed = images.enumerated()
            .filter { $0.element.isImageFile }
            .map { (index: $0.offset, url: $0.element.url) }
        guard !indexed.isEmpty else { return }

        let orientations = await withTaskGroup(of: (Int, Int)?.self) { group in
            for item in indexed {
                group.addTask {
                    guard let source = CGImageSourceCreateWithURL(item.url as CFURL, nil),
                          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          let orientation = props[kCGImagePropertyOrientation] as? Int,
                          orientation != 1 else { return nil }
                    return (item.index, orientation)
                }
            }
            var result: [(Int, Int)] = []
            for await pair in group {
                if let pair { result.append(pair) }
            }
            return result
        }
        for (index, orientation) in orientations {
            images[index].exifOrientation = orientation
        }
    }

    private func loadBasicMetadata(cachedSidecars: [URL: MetadataSidecar] = [:]) async {
        guard exifToolService.isAvailable else { return }
        if isMetadataLoading {
            pendingMetadataURLs.formUnion(images.map(\.url))
            return
        }
        isMetadataLoading = true
        let folderURL = currentFolderURL
        defer {
            isMetadataLoading = false
            drainPendingMetadataIfNeeded()
        }

        do {
            try exifToolService.start()
        } catch {
            return
        }

        // Process in batches — apply each batch directly to self.images so concurrent
        // user edits (rating/label changes) are not overwritten by a stale snapshot.
        // Suppress the images didSet cascade during the loop to avoid N/batchSize
        // redundant sort + filter + UI rebuild cycles; do a single rebuild at the end.
        let batchSize = 50
        let urls = images.filter(\.isImageFile).map(\.url)
        let totalBatchStart = ContinuousClock.now
        let totalBatches = (urls.count + batchSize - 1) / batchSize
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
                let results = try await exifToolService.readBatchBasicMetadata(urls: batchURLs)
                let batchMs = Int(batchTimer.duration(to: .now).components.seconds * 1000)
                    + Int(batchTimer.duration(to: .now).components.attoseconds / 1_000_000_000_000_000)
                perfLog.info("[BrowserVM] batch \(batchIndex)/\(totalBatches) DONE — \(batchURLs.count) files in \(batchMs)ms")
                applyBatchMetadataResults(results, to: &images, localIndex: urlToImageIndex, cachedSidecars: cachedSidecars)
            } catch {
                logger.warning("Batch metadata load failed (batch at offset \(batchStart)): \(error.localizedDescription)")
            }
        }
        let totalMs = Int(totalBatchStart.duration(to: .now).components.seconds * 1000)
            + Int(totalBatchStart.duration(to: .now).components.attoseconds / 1_000_000_000_000_000)
        perfLog.info("[BrowserVM] loadBasicMetadata DONE — \(urls.count) images in \(totalMs)ms")
        rebuildSortedCache()
    }

    private func loadBasicMetadata(for urls: [URL]) async {
        guard exifToolService.isAvailable else { return }
        guard !urls.isEmpty else { return }
        if isMetadataLoading {
            pendingMetadataURLs.formUnion(urls)
            return
        }
        isMetadataLoading = true
        let folderURL = currentFolderURL
        defer {
            isMetadataLoading = false
            drainPendingMetadataIfNeeded()
        }

        do {
            try exifToolService.start()
        } catch {
            return
        }

        let batchSize = 50

        suppressImagesCascade = true
        defer { suppressImagesCascade = false }
        for batchStart in stride(from: 0, to: urls.count, by: batchSize) {
            guard !Task.isCancelled, currentFolderURL == folderURL else { return }
            let batchEnd = min(batchStart + batchSize, urls.count)
            let batchURLs = Array(urls[batchStart..<batchEnd])

            do {
                let results = try await exifToolService.readBatchBasicMetadata(urls: batchURLs)
                applyBatchMetadataResults(results, to: &images, localIndex: urlToImageIndex)
            } catch {
                logger.warning("Incremental metadata load failed: \(error.localizedDescription)")
            }
        }
        rebuildSortedCache()
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

    /// Apply parsed ExifTool batch results to the local ImageFile array.
    /// Shared by full-folder reload and incremental (pending URL) reload paths.
    private func applyBatchMetadataResults(
        _ results: [[String: Any]],
        to updated: inout [ImageFile],
        localIndex: [URL: Int],
        cachedSidecars: [URL: MetadataSidecar] = [:]
    ) {
        for dict in results {
            guard let sourcePath = dict[ExifToolReadKey.sourceFile] as? String else { continue }
            let sourceURL = URL(fileURLWithPath: sourcePath)

            // Bounds-check: localIndex can become stale when images are modified during
            // an async ExifTool await (e.g. user switches folder while batch is in-flight).
            if let index = localIndex[sourceURL], index < updated.count {
                if let rating = dict[ExifToolReadKey.rating] as? Int,
                   let starRating = StarRating(rawValue: rating) {
                    updated[index].starRating = starRating
                }
                updated[index].colorLabel = ColorLabel.fromMetadataLabel(dict[ExifToolReadKey.label] as? String)
                updated[index].personShown = parseStringOrArray(dict[ExifToolReadKey.personInImage])
                updated[index].keywords = mergedKeywords(from: dict)
                updated[index].hasC2PA = TechnicalMetadata.dictHasC2PA(dict)
                updated[index].hasDevelopEdits = hasDevelopEdits(in: dict)
                updated[index].hasCropEdits = hasCropEdits(in: dict)
                updated[index].exifOrientation = parseIntValue(dict[ExifToolReadKey.orientation]) ?? 1
                updated[index].isNativeHDR = SupportedImageFormats.isHDR(url: sourceURL)
                    || (UserDefaults.standard.bool(forKey: UserDefaultsKeys.rawRenderAsHDR) && SupportedImageFormats.isRaw(url: sourceURL))
                updated[index].cropRegion = cropRegion(in: dict, exifOrientation: updated[index].exifOrientation)
                // Preserve in-memory localAdjustments — these are set by the edit
                // workspace and written to the image via ExifTool, not parsed from
                // batch ExifTool XMP output.
                let existingLocalAdjustments = updated[index].cameraRawSettings?.localAdjustments
                var newSettings = cameraRawSettings(in: dict)
                if (existingLocalAdjustments?.isEmpty == false) && newSettings == nil {
                    newSettings = CameraRawSettings()
                }
                if let masks = existingLocalAdjustments, !masks.isEmpty {
                    newSettings?.localAdjustments = masks
                }
                updated[index].cameraRawSettings = newSettings

                // Load XMP sidecar once — fast fileExists check for non-existent files.
                let xmpMeta = xmpSidecarService.loadSidecar(for: sourceURL)

                // ExifTool reads CRS from the image file itself but NOT from the
                // adjacent .xmp sidecar where edited CameraRaw settings are stored.
                // For RAW files, the XMP sidecar is the authoritative CRS source —
                // replace rather than merge to avoid stale embedded values leaking
                // through nil sidecar fields (e.g. Adobe omitting Temperature).
                if SupportedImageFormats.isRaw(url: sourceURL),
                   let xmpCRS = xmpMeta?.cameraRaw, !xmpCRS.isEmpty {
                    var finalCRS = xmpCRS
                    // Preserve in-memory localAdjustments (written to image, not sidecar)
                    if (xmpCRS.localAdjustments?.isEmpty ?? true),
                       let masks = updated[index].cameraRawSettings?.localAdjustments, !masks.isEmpty {
                        finalCRS.localAdjustments = masks
                    }
                    updated[index].cameraRawSettings = finalCRS
                    applySidecarCropState(to: &updated[index], cameraRaw: finalCRS)
                }

                // XMP sidecar rating/label/orientation overrides — written by
                // writeToXMPSidecar mode for C2PA images (and any other images
                // using that mode).  ExifTool only reads from the image file,
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
        let iptc = parseStringOrArray(dict[ExifToolReadKey.keywords])
        let xmp = parseStringOrArray(dict[ExifToolReadKey.subject])
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
        if parseBoolValue(dict[ExifToolReadKey.crsHasSettings]) == true {
            return true
        }
        if parseBoolValue(dict[ExifToolReadKey.crsHasCrop]) == true {
            return true
        }
        let numericKeys: [String] = [
            ExifToolReadKey.crsExposure2012,
            ExifToolReadKey.crsContrast2012,
            ExifToolReadKey.crsHighlights2012,
            ExifToolReadKey.crsShadows2012,
            ExifToolReadKey.crsWhites2012,
            ExifToolReadKey.crsBlacks2012,
            ExifToolReadKey.crsTemperature,
            ExifToolReadKey.crsTint,
            ExifToolReadKey.crsIncrementalTemperature,
            ExifToolReadKey.crsIncrementalTint,
            ExifToolReadKey.crsCropTop,
            ExifToolReadKey.crsCropLeft,
            ExifToolReadKey.crsCropBottom,
            ExifToolReadKey.crsCropRight,
        ]
        for key in numericKeys {
            if let value = parseDoubleValue(dict[key]), abs(value) > 0.0001 {
                return true
            }
        }
        return false
    }

    private func hasCropEdits(in dict: [String: Any]) -> Bool {
        if parseBoolValue(dict[ExifToolReadKey.crsHasCrop]) == true {
            return true
        }

        let top = parseDoubleValue(dict[ExifToolReadKey.crsCropTop]) ?? 0
        let left = parseDoubleValue(dict[ExifToolReadKey.crsCropLeft]) ?? 0
        let bottom = parseDoubleValue(dict[ExifToolReadKey.crsCropBottom]) ?? 1
        let right = parseDoubleValue(dict[ExifToolReadKey.crsCropRight]) ?? 1
        let angle = parseDoubleValue(dict[ExifToolReadKey.crsCropAngle]) ?? 0
        let epsilon = 0.0001

        return abs(top) > epsilon
            || abs(left) > epsilon
            || abs(bottom - 1) > epsilon
            || abs(right - 1) > epsilon
            || abs(angle) > epsilon
    }

    private func cropRegion(in dict: [String: Any], exifOrientation: Int = 1) -> ThumbnailCropRegion? {
        guard hasCropEdits(in: dict) else { return nil }
        let sensorCrop = CameraRawCrop(
            top: parseDoubleValue(dict[ExifToolReadKey.crsCropTop]),
            left: parseDoubleValue(dict[ExifToolReadKey.crsCropLeft]),
            bottom: parseDoubleValue(dict[ExifToolReadKey.crsCropBottom]),
            right: parseDoubleValue(dict[ExifToolReadKey.crsCropRight]),
            angle: parseDoubleValue(dict[ExifToolReadKey.crsCropAngle]),
            hasCrop: parseBoolValue(dict[ExifToolReadKey.crsHasCrop])
        )
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

    private func parseDoubleValue(_ value: Any?) -> Double? {
        if let doubleValue = value as? Double { return doubleValue }
        if let intValue = value as? Int { return Double(intValue) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let stringValue = value as? String {
            return Double(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private func parseIntValue(_ value: Any?) -> Int? {
        if let intValue = value as? Int { return intValue }
        if let doubleValue = value as? Double { return Int(doubleValue) }
        if let number = value as? NSNumber { return number.intValue }
        if let stringValue = value as? String {
            return Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private func parseToneCurveFromExifTool(_ value: Any?) -> [ToneCurvePoint]? {
        guard let array = value as? [String], array.count > 2 else { return nil }
        let points = array.compactMap { str -> ToneCurvePoint? in
            let parts = str.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2,
                  let x = Double(parts[0]),
                  let y = Double(parts[1]) else { return nil }
            return ToneCurvePoint(x: x / 255.0, y: y / 255.0)
        }
        return points.count > 2 ? points : nil
    }

    private func cameraRawSettings(in dict: [String: Any]) -> CameraRawSettings? {
        let crop = CameraRawCrop(
            top: parseDoubleValue(dict[ExifToolReadKey.crsCropTop]),
            left: parseDoubleValue(dict[ExifToolReadKey.crsCropLeft]),
            bottom: parseDoubleValue(dict[ExifToolReadKey.crsCropBottom]),
            right: parseDoubleValue(dict[ExifToolReadKey.crsCropRight]),
            angle: parseDoubleValue(dict[ExifToolReadKey.crsCropAngle]),
            hasCrop: parseBoolValue(dict[ExifToolReadKey.crsHasCrop])
        )
        let cropValue = crop.isEmpty ? nil : crop

        let tcMaster = parseToneCurveFromExifTool(dict[ExifToolReadKey.crsToneCurvePV2012])
        let tcRed = parseToneCurveFromExifTool(dict[ExifToolReadKey.crsToneCurvePV2012Red])
        let tcGreen = parseToneCurveFromExifTool(dict[ExifToolReadKey.crsToneCurvePV2012Green])
        let tcBlue = parseToneCurveFromExifTool(dict[ExifToolReadKey.crsToneCurvePV2012Blue])
        let toneCurve: ToneCurve? = {
            let tc = ToneCurve(master: tcMaster, red: tcRed, green: tcGreen, blue: tcBlue)
            return tc.isEmpty ? nil : tc
        }()

        let settings = CameraRawSettings(
            version: dict[ExifToolReadKey.crsVersion] as? String,
            processVersion: dict[ExifToolReadKey.crsProcessVersion] as? String,
            whiteBalance: dict[ExifToolReadKey.crsWhiteBalance] as? String,
            temperature: parseIntValue(dict[ExifToolReadKey.crsTemperature]),
            tint: parseIntValue(dict[ExifToolReadKey.crsTint]),
            incrementalTemperature: parseIntValue(dict[ExifToolReadKey.crsIncrementalTemperature]),
            incrementalTint: parseIntValue(dict[ExifToolReadKey.crsIncrementalTint]),
            exposure2012: parseDoubleValue(dict[ExifToolReadKey.crsExposure2012]),
            contrast2012: parseIntValue(dict[ExifToolReadKey.crsContrast2012]),
            highlights2012: parseIntValue(dict[ExifToolReadKey.crsHighlights2012]),
            shadows2012: parseIntValue(dict[ExifToolReadKey.crsShadows2012]),
            whites2012: parseIntValue(dict[ExifToolReadKey.crsWhites2012]),
            blacks2012: parseIntValue(dict[ExifToolReadKey.crsBlacks2012]),
            saturation: parseIntValue(dict[ExifToolReadKey.crsSaturation]),
            vibrance: parseIntValue(dict[ExifToolReadKey.crsVibrance]),
            hasSettings: parseBoolValue(dict[ExifToolReadKey.crsHasSettings]),
            crop: cropValue,
            hdrEditMode: parseIntValue(dict[ExifToolReadKey.crsHDREditMode]),
            hdrMaxValue: dict[ExifToolReadKey.crsHDRMaxValue] as? String,
            sdrBrightness: parseIntValue(dict[ExifToolReadKey.crsSDRBrightness]),
            sdrContrast: parseIntValue(dict[ExifToolReadKey.crsSDRContrast]),
            sdrClarity: parseIntValue(dict[ExifToolReadKey.crsSDRClarity]),
            sdrHighlights: parseIntValue(dict[ExifToolReadKey.crsSDRHighlights]),
            sdrShadows: parseIntValue(dict[ExifToolReadKey.crsSDRShadows]),
            sdrWhites: parseIntValue(dict[ExifToolReadKey.crsSDRWhites]),
            sdrBlend: parseIntValue(dict[ExifToolReadKey.crsSDRBlend]),
            toneCurve: toneCurve
        )
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
            writeToExifTool: { try await self.exifToolService.writeRating(rating, to: $0) },
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
            writeToExifTool: { try await self.exifToolService.writeLabel(label, to: $0) },
            fieldDescription: "label"
        )
    }

    func rotateClockwise() {
        guard !selectedImageIDs.isEmpty else { return }
        var newOrientations: [URL: Int] = [:]
        for image in selectedImages {
            newOrientations[image.url] = ImageFile.orientationAfterClockwiseRotation(image.exifOrientation)
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
            writeToExifTool: { urls in
                var byOrientation: [Int: [URL]] = [:]
                for url in urls {
                    let orientation = newOrientations[url] ?? 1
                    byOrientation[orientation, default: []].append(url)
                }
                for (orientation, batchURLs) in byOrientation {
                    try await self.exifToolService.writeOrientation(orientation, to: batchURLs)
                }
            },
            fieldDescription: "orientation"
        )
        for url in selectedImages.map(\.url) {
            thumbnailService.rotateThumbnailInCache(for: url, clockwise: true)
        }
    }

    func rotateCounterclockwise() {
        guard !selectedImageIDs.isEmpty else { return }
        var newOrientations: [URL: Int] = [:]
        for image in selectedImages {
            newOrientations[image.url] = ImageFile.orientationAfterCounterclockwiseRotation(image.exifOrientation)
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
            writeToExifTool: { urls in
                var byOrientation: [Int: [URL]] = [:]
                for url in urls {
                    let orientation = newOrientations[url] ?? 1
                    byOrientation[orientation, default: []].append(url)
                }
                for (orientation, batchURLs) in byOrientation {
                    try await self.exifToolService.writeOrientation(orientation, to: batchURLs)
                }
            },
            fieldDescription: "orientation"
        )
        for url in selectedImages.map(\.url) {
            thumbnailService.rotateThumbnailInCache(for: url, clockwise: false)
        }
    }

    private func applyMetadataField(
        updateImage: (inout ImageFile) -> Void,
        affectsSortKey: Bool,
        affectsFilterKey: Bool,
        applySidecar: @escaping (URL, Bool, Bool) async -> Void,
        writeToExifTool: @escaping ([URL]) async throws -> Void,
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
                let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                var needsFullRebuild = false
                for url in selectedImageIDs {
                    guard let imageIdx = urlToImageIndex[url] else { continue }
                    let updatedImage = images[imageIdx]
                    let passes = imagePassesFilter(updatedImage, query: query)
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

        Task {
            var writeToFileWithSidecar: [URL] = []
            var writeToFileWithoutSidecar: [URL] = []
            var writeToSidecar: [URL] = []
            var writeToXmp: [URL] = []
            var syncPairRawURLs: Set<URL> = []
            var syncMissingPairs = 0
            var syncMultiplePairs = 0

            let strictPM = PMXMPPolicy.mode == .strictPhotoMechanic
            var strictNonRawChoice: PMNonRAWXMPSidecarChoice?
            if strictPM {
                let hasNonRawXMPTarget = urls.contains { url in
                    let hasC2PA = c2paByURL[url] ?? false
                    let mode = MetadataWriteMode.current(forC2PA: hasC2PA)
                    return mode == .writeToXMPSidecar && !SupportedImageFormats.isRaw(url: url)
                }
                if hasNonRawXMPTarget {
                    strictNonRawChoice = await MainActor.run {
                        PMXMPPolicy.resolveNonRawChoiceWithPromptIfNeeded()
                    }
                    guard strictNonRawChoice != nil else { return }
                }
            }

            for url in urls {
                let hasC2PA = c2paByURL[url] ?? false
                let mode = MetadataWriteMode.current(forC2PA: hasC2PA)

                switch mode {
                case .historyOnly:
                    writeToSidecar.append(url)
                case .writeToXMPSidecar:
                    if strictPM, !SupportedImageFormats.isRaw(url: url), let choice = strictNonRawChoice {
                        switch choice {
                        case .historyOnly:
                            writeToSidecar.append(url)
                        case .embeddedWrite:
                            writeToFileWithoutSidecar.append(url)
                        case .syncRawJpegPair:
                            writeToFileWithoutSidecar.append(url)
                            if let pair = SupportedImageFormats.preferredRawSibling(for: url) {
                                syncPairRawURLs.insert(pair.url)
                                if pair.hadMultipleMatches {
                                    syncMultiplePairs += 1
                                }
                            } else {
                                syncMissingPairs += 1
                            }
                        }
                    } else {
                        writeToXmp.append(url)
                    }
                case .writeToFile:
                    writeToFileWithSidecar.append(url)
                }
            }

            for rawURL in syncPairRawURLs where !writeToXmp.contains(rawURL) {
                writeToXmp.append(rawURL)
            }

            for url in writeToSidecar {
                await applySidecar(url, false, true)
            }
            for url in writeToXmp {
                await applySidecar(url, true, false)
            }
            for url in writeToFileWithSidecar {
                await applySidecar(url, false, false)
            }

            let fileWriteTargets = writeToFileWithSidecar + writeToFileWithoutSidecar
            if exifToolService.isAvailable, !fileWriteTargets.isEmpty {
                do {
                    try await writeToExifTool(fileWriteTargets)
                    clearMetadataSidecars(for: writeToFileWithoutSidecar)
                } catch {
                    self.errorMessage = "Failed to write \(fieldDescription): \(error.localizedDescription)"
                }
            }

            if syncMissingPairs > 0 || syncMultiplePairs > 0 {
                var notes: [String] = []
                if syncMissingPairs > 0 {
                    notes.append("\(syncMissingPairs) file(s) had no RAW sibling")
                }
                if syncMultiplePairs > 0 {
                    notes.append("\(syncMultiplePairs) file(s) matched multiple RAW siblings")
                }
                self.errorMessage = "Sync RAW+JPEG: " + notes.joined(separator: ", ") + "."
            }

            let allAffectedURLs = urls + Array(syncPairRawURLs)
            await MainActor.run {
                self.refreshPendingStatusBatch(for: allAffectedURLs)
            }
        }
    }

    private func clearMetadataSidecars(for urls: [URL]) {
        guard let folderURL = currentFolderURL, !urls.isEmpty else { return }
        for url in urls {
            try? sidecarService.deleteSidecar(for: url, in: folderURL)
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
    /// until ExifTool metadata is read (which populates cameraRaw from XMP).
    private func applySidecarCropAndDevelopState(to imageFile: inout ImageFile, sidecar: MetadataSidecar) {
        // Camera raw data is sourced from XMP only, not from JSON sidecar.
        // Crop/develop state will be applied when ExifTool metadata loads.
    }

    private func applySidecarCropState(to imageFile: inout ImageFile, cameraRaw: CameraRawSettings?) {
        if let cameraRaw, let crop = cameraRaw.crop, !crop.isEmpty {
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
            if let cameraRaw, !cameraRaw.isEmpty {
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
            snapshot = await loadMetadataSnapshot(for: url, includeXmp: writeXmpSidecar)
        }

        if !hadSidecar, let snapshot {
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
            do {
                try xmpSidecarService.saveSidecar(metadata: metadata, for: url)
            } catch {
                errorMessage = "Failed to save XMP sidecar: \(error.localizedDescription)"
            }
        }
    }

    private func loadMetadataSnapshot(for url: URL, includeXmp: Bool) async -> IPTCMetadata? {
        do {
            var metadata = try await exifToolService.readFullMetadata(url: url)
            let preferXmp = UserDefaults.standard.bool(forKey: UserDefaultsKeys.metadataPreferXMPSidecar)
            if (includeXmp || preferXmp),
               PMXMPPolicy.shouldUseXMPReference(for: url),
               let xmpMetadata = xmpSidecarService.loadSidecar(for: url) {
                metadata = metadata.merged(preferring: xmpMetadata)
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
        favoriteFolders = decoded
    }

    private func saveFavorites() {
        if let data = try? JSONEncoder().encode(favoriteFolders) {
            UserDefaults.standard.set(data, forKey: favoritesKey)
        }
    }

    func loadFavoriteTopLevelSubfolders() {
        for favorite in favoriteFolders {
            let url = favorite.url
            guard subfoldersByOpenFolder[url] == nil else { continue }
            let subfolders = (try? fileSystemService.listSubfolders(at: url)) ?? []
            subfoldersByOpenFolder[url] = subfolders
        }
    }

    /// Lazily loads direct subfolders for a URL if not already cached.
    func ensureSubfoldersLoaded(for url: URL) {
        guard subfoldersByOpenFolder[url] == nil else { return }
        let discovered = (try? fileSystemService.listSubfolders(at: url)) ?? []
        subfoldersByOpenFolder[url] = discovered
    }

    /// Toggles expansion of a folder in the sidebar, triggering lazy load on first expand.
    func toggleFolderExpansion(_ url: URL) {
        if expandedFolders.contains(url) {
            expandedFolders.remove(url)
        } else {
            expandedFolders.insert(url)
            ensureSubfoldersLoaded(for: url)
        }
    }

    /// Recursively removes all cached subfolder entries rooted at a URL.
    private func removeSubfolderCacheRecursively(for url: URL) {
        guard let children = subfoldersByOpenFolder.removeValue(forKey: url) else { return }
        expandedFolders.remove(url)
        for child in children {
            removeSubfolderCacheRecursively(for: child)
        }
    }

    func addCurrentFolderToFavorites() {
        guard let url = currentFolderURL else { return }
        guard !favoriteFolders.contains(where: { $0.url == url }) else { return }
        favoriteFolders.append(FavoriteFolder(url: url))
        saveFavorites()
        loadFavoriteTopLevelSubfolders()
    }

    func addFolderToFavorites(_ url: URL) {
        guard !favoriteFolders.contains(where: { $0.url == url }) else { return }
        favoriteFolders.append(FavoriteFolder(url: url))
        saveFavorites()
        loadFavoriteTopLevelSubfolders()
    }

    func removeFavorite(_ favorite: FavoriteFolder) {
        favoriteFolders.removeAll { $0.id == favorite.id }
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

    // MARK: - Recent Folders

    func loadRecentFolders() {
        guard let data = UserDefaults.standard.data(forKey: recentFoldersKey),
              let decoded = try? JSONDecoder().decode([RecentFolder].self, from: data) else {
            return
        }
        recentFolders = decoded
    }

    private func saveRecentFolders() {
        if let data = try? JSONEncoder().encode(recentFolders) {
            UserDefaults.standard.set(data, forKey: recentFoldersKey)
        }
    }

    private func trackRecentFolder(url: URL) {
        recentFolders.removeAll { $0.url == url }
        recentFolders.insert(RecentFolder(url: url), at: 0)
        if recentFolders.count > 3 {
            recentFolders = Array(recentFolders.prefix(3))
        }
        saveRecentFolders()
    }

    // MARK: - Subfolder Actions

    func openSubfolderAsRoot(_ url: URL) {
        if !openFolders.contains(url) {
            openFolders.append(url)
        }
        loadFolder(url: url)
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
        let trimmed = renameSubfolderNewName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != oldURL.lastPathComponent else { return }

        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(trimmed, isDirectory: true)
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

        // Remove all cached descendants of the old path (they have stale URLs)
        removeSubfolderCacheRecursively(for: oldURL)

        // Update expansion state and re-discover children of renamed folder
        if expandedFolders.remove(oldURL) != nil {
            expandedFolders.insert(newURL)
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
        let trimmed = newSubfolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Subfolder name can't be empty."
            return
        }
        if trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "/:")) != nil {
            errorMessage = "Subfolder name can't contain / or : characters."
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
        expandedFolders.insert(parentURL)
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

        do {
            try FileManager.default.moveItem(at: sourceURL, to: newURL)
        } catch {
            errorMessage = "Failed to move folder: \(error.localizedDescription)"
            return
        }

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
        expandedFolders.insert(destinationURL)

        // Update favorites if the moved folder was a favorite root
        if let favIndex = favoriteFolders.firstIndex(where: { $0.url == sourceURL }) {
            favoriteFolders[favIndex].url = newURL
            favoriteFolders[favIndex].name = newURL.lastPathComponent
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
        if edited.country != original.country { names.append("Country") }
        if edited.event != original.event { names.append("Event") }
        if edited.digitalSourceType != original.digitalSourceType { names.append("Digital Source Type") }
        if edited.exifOrientation != original.exifOrientation { names.append("Orientation") }
        if edited.latitude != original.latitude || edited.longitude != original.longitude { names.append("GPS Coordinates") }
        if edited.captureDate != original.captureDate { names.append("Capture Date") }
        return names
    }

    func refreshPendingStatus() {
        guard let folderURL = currentFolderURL else { return }
        let allSidecars = sidecarService.loadAllSidecars(in: folderURL)
        var updated = images
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
        images = updated
    }

    func refreshPendingStatusBatch(for urls: [URL]) {
        guard let folderURL = currentFolderURL, !urls.isEmpty else { return }
        let urlSet = Set(urls)
        var updated = images
        for i in updated.indices where urlSet.contains(updated[i].url) {
            let sidecar = sidecarService.loadSidecar(for: updated[i].url, in: folderURL)
            if let sidecar, sidecar.pendingChanges {
                updated[i].hasPendingMetadataChanges = true
                updated[i].pendingFieldNames = extractPendingFieldNames(from: sidecar)
                applyPendingSidecarOverrides(to: &updated, for: updated[i].url, index: i, cachedSidecar: sidecar)
            } else {
                updated[i].hasPendingMetadataChanges = false
                updated[i].pendingFieldNames = []
            }
        }
        images = updated
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

    func deleteSelectedImages() {
        let urlsToDelete = selectedImageIDs
        guard !urlsToDelete.isEmpty else { return }

        for url in urlsToDelete {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                // Skip files that can't be trashed
                continue
            }
        }

        images.removeAll { urlsToDelete.contains($0.url) }
        manualOrder.removeAll { urlsToDelete.contains($0) }
        selectedImageIDs.removeAll()
        lastClickedImageURL = nil
        onImagesDeleted?(urlsToDelete)
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
        expandedFolders.insert(folderURL)
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

        let urlsToMove = selectedImageIDs
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

                // Move metadata sidecar
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
            presentMoveErrorAlert(message: "Failed to move \(failures.count) item(s):\n" + failures.prefix(5).joined(separator: "\n"))
        }
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
        }

        // Clear CRS from XMP sidecars for RAW files — the sidecar is the
        // authoritative CRS source and would re-set hasDevelopEdits on next load.
        for url in urls where SupportedImageFormats.isRaw(url: url) {
            do {
                try xmpSidecarService.saveCameraRawOnly(nil, orientation: nil, for: url)
            } catch {
                logger.error("Failed to clear CRS from XMP sidecar for \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        // Write cleared CRS fields to XMP in the image files
        Task {
            var clearFields: [String: String] = [:]
            clearFields[ExifToolWriteTag.crsVersion] = ""
            clearFields[ExifToolWriteTag.crsProcessVersion] = ""
            clearFields[ExifToolWriteTag.crsWhiteBalance] = ""
            clearFields[ExifToolWriteTag.crsTemperature] = ""
            clearFields[ExifToolWriteTag.crsTint] = ""
            clearFields[ExifToolWriteTag.crsIncrementalTemperature] = ""
            clearFields[ExifToolWriteTag.crsIncrementalTint] = ""
            clearFields[ExifToolWriteTag.crsExposure2012] = ""
            clearFields[ExifToolWriteTag.crsContrast2012] = ""
            clearFields[ExifToolWriteTag.crsHighlights2012] = ""
            clearFields[ExifToolWriteTag.crsShadows2012] = ""
            clearFields[ExifToolWriteTag.crsWhites2012] = ""
            clearFields[ExifToolWriteTag.crsBlacks2012] = ""
            clearFields[ExifToolWriteTag.crsSaturation] = ""
            clearFields[ExifToolWriteTag.crsVibrance] = ""
            clearFields[ExifToolWriteTag.crsHasSettings] = "False"
            clearFields[ExifToolWriteTag.crsCropTop] = ""
            clearFields[ExifToolWriteTag.crsCropLeft] = ""
            clearFields[ExifToolWriteTag.crsCropBottom] = ""
            clearFields[ExifToolWriteTag.crsCropRight] = ""
            clearFields[ExifToolWriteTag.crsCropAngle] = ""
            clearFields[ExifToolWriteTag.crsHasCrop] = ""
            clearFields[ExifToolWriteTag.crsCropConstrainToWarp] = ""
            clearFields[ExifToolWriteTag.crsCropConstrainToUnitSquare] = ""
            clearFields[ExifToolWriteTag.crsHDREditMode] = ""
            clearFields[ExifToolWriteTag.crsHDRMaxValue] = ""
            clearFields[ExifToolWriteTag.crsSDRBrightness] = ""
            clearFields[ExifToolWriteTag.crsSDRContrast] = ""
            clearFields[ExifToolWriteTag.crsSDRClarity] = ""
            clearFields[ExifToolWriteTag.crsSDRHighlights] = ""
            clearFields[ExifToolWriteTag.crsSDRShadows] = ""
            clearFields[ExifToolWriteTag.crsSDRWhites] = ""
            clearFields[ExifToolWriteTag.crsSDRBlend] = ""

            // Clear masks via structured XMP arg
            let maskClearArgs = ["-struct", "-\(ExifToolWriteTag.crsMaskGroupBasedCorrections)="]

            do {
                try await exifToolService.writeFields(clearFields, to: urls, extraArgs: maskClearArgs)
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

        Task {
            do {
                try await exifToolService.stripIPTCAndXMP(from: urls)
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

    struct FolderFilterState {
        var minimumStarRating: StarRating = .none
        var selectedColorLabels: Set<ColorLabel> = []
        var personShownFilter: PersonShownFilter = .any
        var editedFilter: EditedFilter = .any
        var searchText: String = ""
    }

    private func saveCurrentFilterState() {
        guard let url = currentFolderURL else { return }
        folderFilterStates[url] = FolderFilterState(
            minimumStarRating: minimumStarRating,
            selectedColorLabels: selectedColorLabels,
            personShownFilter: personShownFilter,
            editedFilter: editedFilter,
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
                searchText = saved.searchText
            } else {
                minimumStarRating = .none
                selectedColorLabels = []
                personShownFilter = .any
                editedFilter = .any
                searchText = ""
            }
        }
    }
}
