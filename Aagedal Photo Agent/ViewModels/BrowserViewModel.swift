import Foundation
import AppKit
import os

@Observable
final class BrowserViewModel {
    var images: [ImageFile] = [] {
        didSet {
            urlToImageIndex = Dictionary(uniqueKeysWithValues: images.enumerated().map { ($1.url, $0) })
            let sameSet = images.count == oldValue.count
            rebuildSortedCache(forceSort: !sameSet)
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
            rebuildSortedCache()
        }
    }
    var favoriteFolders: [FavoriteFolder] = []
    var openFolders: [URL] = []
    var subfoldersByOpenFolder: [URL: [URL]] = [:]
    var expandedFolders: Set<URL> = []
    var manualOrder: [URL] = [] {
        didSet {
            if sortOrder == .manual { rebuildSortedCache() }
        }
    }
    @ObservationIgnored var draggedImageURLs: Set<URL> = []
    var searchText: String = "" {
        didSet {
            searchDebounceTask?.cancel()
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rebuildVisibleCache()
            } else {
                searchDebounceTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled else { return }
                    self?.rebuildVisibleCache()
                }
            }
        }
    }
    var minimumStarRating: StarRating = .none {
        didSet { scheduleFilterRebuild() }
    }
    var selectedColorLabels: Set<ColorLabel> = [] {
        didSet { scheduleFilterRebuild() }
    }
    var personShownFilter: PersonShownFilter = .any {
        didSet { scheduleFilterRebuild() }
    }

    var thumbnailScale: Double = 1.0 {
        didSet {
            UserDefaults.standard.set(thumbnailScale, forKey: UserDefaultsKeys.thumbnailScale)
        }
    }

    var copiedCameraRawSettings: CameraRawSettings?

    let fileSystemService = FileSystemService()
    let thumbnailService = ThumbnailService()
    let exifToolService = ExifToolService()
    private let sidecarService = MetadataSidecarService()
    private let xmpSidecarService = XMPSidecarService()

    private let logger = Logger(subsystem: "com.aagedal.photo-agent", category: "BrowserViewModel")
    @ObservationIgnored var onImagesDeleted: ((Set<URL>) -> Void)?
    @ObservationIgnored private var searchDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var filterDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var isAutoRefreshing = false
    @ObservationIgnored private var isMetadataLoading = false
    @ObservationIgnored private var pendingMetadataURLs: Set<URL> = []

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
    }

    @ObservationIgnored private(set) var selectedImagesCache: [ImageFile] = []

    init() {
        if let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.thumbnailSortOrder),
           let stored = SortOrder(rawValue: raw) {
            sortOrder = stored
        }
        let storedScale = UserDefaults.standard.double(forKey: UserDefaultsKeys.thumbnailScale)
        if storedScale >= 0.5 && storedScale <= 2.0 {
            thumbnailScale = storedScale
        }
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
            sortedImages = sorted
            urlToSortedIndex = Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($1.url, $0) })
        } else {
            // Same images, just updated properties — refresh sortedImages in existing order
            let imageByURL = Dictionary(uniqueKeysWithValues: images.map { ($0.url, $0) })
            sortedImages = sortedImages.compactMap { imageByURL[$0.url] }
        }
        rebuildVisibleCache()
    }

    private func scheduleFilterRebuild() {
        filterDebounceTask?.cancel()
        filterDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            self?.rebuildVisibleCache()
        }
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
    }

    private func applyFilters(to images: [ImageFile]) -> [ImageFile] {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = trimmedQuery.lowercased()

        return images.filter { image in
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
            guard !query.isEmpty else { return true }
            if image.filenameLowercased.contains(query) {
                return true
            }
            return image.personShown.contains { $0.lowercased().contains(query) }
        }
    }

    func clearFilters() {
        searchText = ""
        minimumStarRating = .none
        selectedColorLabels.removeAll()
        personShownFilter = .any
    }

    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadFolder(url: url)
    }

    func loadFolder(url: URL) {
        currentFolderURL = url
        currentFolderName = url.lastPathComponent
        isLoading = true
        errorMessage = nil
        selectedImageIDs.removeAll()
        lastClickedImageURL = nil
        manualOrder.removeAll()

        // Add to open folders if not already there, unless it's a subfolder of an existing open folder
        if !openFolders.contains(url) && !isSubfolderOfOpenFolder(url) {
            openFolders.append(url)
        }

        Task {
            let discoveredSubfolders = (try? fileSystemService.listSubfolders(at: url)) ?? []
            self.subfoldersByOpenFolder[url] = discoveredSubfolders
            if !discoveredSubfolders.isEmpty {
                self.expandedFolders.insert(url)
            }
            do {
                var files = try fileSystemService.scanFolder(at: url)
                let allSidecars = sidecarService.loadAllSidecars(in: url)
                for i in files.indices {
                    if let sidecar = allSidecars[files[i].url], sidecar.pendingChanges {
                        files[i].hasPendingMetadataChanges = true
                        files[i].pendingFieldNames = extractPendingFieldNames(from: sidecar)
                    }
                }
                self.images = files
                self.isLoading = false
                await loadBasicMetadata(cachedSidecars: allSidecars)
            } catch {
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
                scanned = try fileSystemService.scanFolder(at: folderURL)
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
                    updated.hasPendingMetadataChanges = existing.hasPendingMetadataChanges
                    updated.pendingFieldNames = existing.pendingFieldNames
                    updated.metadata = existing.metadata
                    updated.personShown = existing.personShown
                    merged.append(updated)
                    if isModified {
                        modifiedURLs.append(item.url)
                    }
                } else {
                    merged.append(item)
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

            let metadataRefreshURLs = newURLs + modifiedURLs
            if !metadataRefreshURLs.isEmpty {
                pendingMetadataURLs.formUnion(metadataRefreshURLs)
                drainPendingMetadataIfNeeded()
            }
        }
    }

    private func loadBasicMetadata(cachedSidecars: [URL: MetadataSidecar] = [:]) async {
        guard exifToolService.isAvailable else { return }
        if isMetadataLoading {
            pendingMetadataURLs.formUnion(images.map(\.url))
            return
        }
        isMetadataLoading = true
        defer {
            isMetadataLoading = false
            drainPendingMetadataIfNeeded()
        }

        do {
            try exifToolService.start()
        } catch {
            return
        }

        // Process in batches — mutate a local copy, assign once to avoid repeated didSet cascades
        let batchSize = 50
        let urls = images.map(\.url)
        var updated = images

        for batchStart in stride(from: 0, to: urls.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, urls.count)
            let batchURLs = Array(urls[batchStart..<batchEnd])

            do {
                let results = try await exifToolService.readBatchBasicMetadata(urls: batchURLs)
                for dict in results {
                    guard let sourcePath = dict[ExifToolReadKey.sourceFile] as? String else { continue }
                    let sourceURL = URL(fileURLWithPath: sourcePath)

                    if let index = urlToImageIndex[sourceURL] {
                        if let rating = dict[ExifToolReadKey.rating] as? Int,
                           let starRating = StarRating(rawValue: rating) {
                            updated[index].starRating = starRating
                        }
                        updated[index].colorLabel = ColorLabel.fromMetadataLabel(dict[ExifToolReadKey.label] as? String)
                        updated[index].personShown = parseStringOrArray(dict[ExifToolReadKey.personInImage])
                        let hasC2PA = TechnicalMetadata.dictHasC2PA(dict)
                        updated[index].hasC2PA = hasC2PA
                        updated[index].hasDevelopEdits = hasDevelopEdits(in: dict)
                        updated[index].hasCropEdits = hasCropEdits(in: dict)
                        updated[index].exifOrientation = parseIntValue(dict[ExifToolReadKey.orientation]) ?? 1
                        updated[index].cropRegion = cropRegion(in: dict, exifOrientation: updated[index].exifOrientation)
                        updated[index].cameraRawSettings = cameraRawSettings(in: dict)
                        applyPendingSidecarOverrides(to: &updated, for: sourceURL, index: index, cachedSidecar: cachedSidecars[sourceURL])
                    }
                }
            } catch {
                logger.warning("Batch metadata load failed (batch at offset \(batchStart)): \(error.localizedDescription)")
            }
        }
        images = updated
    }

    private func loadBasicMetadata(for urls: [URL]) async {
        guard exifToolService.isAvailable else { return }
        guard !urls.isEmpty else { return }
        if isMetadataLoading {
            pendingMetadataURLs.formUnion(urls)
            return
        }
        isMetadataLoading = true
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
        var updated = images

        for batchStart in stride(from: 0, to: urls.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, urls.count)
            let batchURLs = Array(urls[batchStart..<batchEnd])

            do {
                let results = try await exifToolService.readBatchBasicMetadata(urls: batchURLs)
                for dict in results {
                    guard let sourcePath = dict[ExifToolReadKey.sourceFile] as? String else { continue }
                    let sourceURL = URL(fileURLWithPath: sourcePath)

                    if let index = urlToImageIndex[sourceURL] {
                        if let rating = dict[ExifToolReadKey.rating] as? Int,
                           let starRating = StarRating(rawValue: rating) {
                            updated[index].starRating = starRating
                        }
                        updated[index].colorLabel = ColorLabel.fromMetadataLabel(dict[ExifToolReadKey.label] as? String)
                        updated[index].personShown = parseStringOrArray(dict[ExifToolReadKey.personInImage])
                        let hasC2PA = TechnicalMetadata.dictHasC2PA(dict)
                        updated[index].hasC2PA = hasC2PA
                        updated[index].hasDevelopEdits = hasDevelopEdits(in: dict)
                        updated[index].hasCropEdits = hasCropEdits(in: dict)
                        updated[index].exifOrientation = parseIntValue(dict[ExifToolReadKey.orientation]) ?? 1
                        updated[index].cropRegion = cropRegion(in: dict, exifOrientation: updated[index].exifOrientation)
                        updated[index].cameraRawSettings = cameraRawSettings(in: dict)
                        applyPendingSidecarOverrides(to: &updated, for: sourceURL, index: index)
                    }
                }
            } catch {
                logger.warning("Incremental metadata load failed: \(error.localizedDescription)")
            }
        }
        images = updated
    }

    private func drainPendingMetadataIfNeeded() {
        guard !isMetadataLoading else { return }
        guard !pendingMetadataURLs.isEmpty else { return }
        let urls = Array(pendingMetadataURLs)
        pendingMetadataURLs.removeAll()
        Task {
            await loadBasicMetadata(for: urls)
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
            crop: cropValue
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
            let firstItem = navigationItems[0]
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

    func selectNext(extending: Bool = false) {
        if navigateFullScreenFaceSequence(step: 1) { return }
        guard !visibleImages.isEmpty else { return }
        let anchor = lastClickedImageURL ?? selectedImageIDs.first
        guard let anchorURL = anchor,
              let currentIndex = urlToVisibleIndex[anchorURL] else {
            selectedImageIDs = [visibleImages[0].url]
            lastClickedImageURL = visibleImages[0].url
            return
        }
        let nextIndex = min(currentIndex + 1, visibleImages.count - 1)
        let nextURL = visibleImages[nextIndex].url
        if extending {
            var updated = selectedImageIDs
            updated.insert(nextURL)
            selectedImageIDs = updated
        } else {
            selectedImageIDs = [nextURL]
        }
        lastClickedImageURL = nextURL
    }

    func selectPrevious(extending: Bool = false) {
        if navigateFullScreenFaceSequence(step: -1) { return }
        guard !visibleImages.isEmpty else { return }
        let anchor = lastClickedImageURL ?? selectedImageIDs.first
        guard let anchorURL = anchor,
              let currentIndex = urlToVisibleIndex[anchorURL] else {
            selectedImageIDs = [visibleImages[0].url]
            lastClickedImageURL = visibleImages[0].url
            return
        }
        let prevIndex = max(currentIndex - 1, 0)
        let prevURL = visibleImages[prevIndex].url
        if extending {
            var updated = selectedImageIDs
            updated.insert(prevURL)
            selectedImageIDs = updated
        } else {
            selectedImageIDs = [prevURL]
        }
        lastClickedImageURL = prevURL
    }

    /// Navigate down one row in a grid layout
    func selectDown(columns: Int, extending: Bool = false) {
        guard !visibleImages.isEmpty, columns > 0 else { return }
        let anchor = lastClickedImageURL ?? selectedImageIDs.first
        guard let anchorURL = anchor,
              let currentIndex = urlToVisibleIndex[anchorURL] else {
            selectedImageIDs = [visibleImages[0].url]
            lastClickedImageURL = visibleImages[0].url
            return
        }
        let targetIndex = min(currentIndex + columns, visibleImages.count - 1)
        let targetURL = visibleImages[targetIndex].url
        if extending {
            // Select all images between current and target
            var updated = selectedImageIDs
            if targetIndex > currentIndex {
                for i in (currentIndex + 1)...targetIndex {
                    updated.insert(visibleImages[i].url)
                }
            }
            selectedImageIDs = updated
        } else {
            selectedImageIDs = [targetURL]
        }
        lastClickedImageURL = targetURL
    }

    /// Navigate up one row in a grid layout
    func selectUp(columns: Int, extending: Bool = false) {
        guard !visibleImages.isEmpty, columns > 0 else { return }
        let anchor = lastClickedImageURL ?? selectedImageIDs.first
        guard let anchorURL = anchor,
              let currentIndex = urlToVisibleIndex[anchorURL] else {
            selectedImageIDs = [visibleImages[0].url]
            lastClickedImageURL = visibleImages[0].url
            return
        }
        let targetIndex = max(currentIndex - columns, 0)
        let targetURL = visibleImages[targetIndex].url
        if extending {
            // Select all images between target and current
            var updated = selectedImageIDs
            if targetIndex < currentIndex {
                for i in targetIndex..<currentIndex {
                    updated.insert(visibleImages[i].url)
                }
            }
            selectedImageIDs = updated
        } else {
            selectedImageIDs = [targetURL]
        }
        lastClickedImageURL = targetURL
    }

    /// Select all images in the current folder
    func selectAll() {
        guard !visibleImages.isEmpty else { return }
        selectedImageIDs = Set(visibleImages.map(\.url))
        // Keep the anchor at the first image or current anchor
        if lastClickedImageURL == nil {
            lastClickedImageURL = visibleImages.first?.url
        }
    }

    // MARK: - Rating & Labels

    func setRating(_ rating: StarRating) {
        applyMetadataField(
            updateImage: { $0.starRating = rating },
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
            thumbnailService.invalidateThumbnail(for: url)
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
            thumbnailService.invalidateThumbnail(for: url)
        }
    }

    private func applyMetadataField(
        updateImage: (inout ImageFile) -> Void,
        applySidecar: @escaping (URL, Bool, Bool) async -> Void,
        writeToExifTool: @escaping ([URL]) async throws -> Void,
        fieldDescription: String
    ) {
        guard !selectedImageIDs.isEmpty else { return }
        let urls = selectedImages.map(\.url)
        let lookup = Dictionary(uniqueKeysWithValues: images.map { ($0.url, $0) })

        var updated = images
        for id in selectedImageIDs {
            if let index = urlToImageIndex[id] {
                updateImage(&updated[index])
            }
        }
        images = updated

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
                    let hasC2PA = lookup[url]?.hasC2PA ?? false
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
                let hasC2PA = lookup[url]?.hasC2PA ?? false
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
        } else {
            if let ratingValue = sidecar.metadata.rating {
                array[index].starRating = StarRating(rawValue: ratingValue) ?? .none
            }
            array[index].colorLabel = ColorLabel.fromMetadataLabel(sidecar.metadata.label)
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

    func addCurrentFolderToFavorites() {
        guard let url = currentFolderURL else { return }
        guard !favoriteFolders.contains(where: { $0.url == url }) else { return }
        favoriteFolders.append(FavoriteFolder(url: url))
        saveFavorites()
    }

    func removeFavorite(_ favorite: FavoriteFolder) {
        favoriteFolders.removeAll { $0.id == favorite.id }
        saveFavorites()
    }

    var isCurrentFolderFavorited: Bool {
        guard let url = currentFolderURL else { return false }
        return favoriteFolders.contains { $0.url == url }
    }

    func closeOpenFolder(_ url: URL) {
        // Clean up subfolder entries that belong to this open folder
        let childURLs = subfoldersByOpenFolder[url] ?? []
        for child in childURLs {
            subfoldersByOpenFolder.removeValue(forKey: child)
        }
        openFolders.removeAll { $0 == url }
        subfoldersByOpenFolder.removeValue(forKey: url)
        expandedFolders.remove(url)
        // If we closed the current folder (or it was browsing a subfolder of this folder),
        // switch to another open folder or clear
        let currentIsChild = childURLs.contains(currentFolderURL ?? URL(fileURLWithPath: "/"))
        if currentFolderURL == url || currentIsChild {
            if let nextFolder = openFolders.first {
                loadFolder(url: nextFolder)
            } else {
                currentFolderURL = nil
                currentFolderName = nil
                images = []
                selectedImageIDs.removeAll()
                subfoldersByOpenFolder = [:]
            }
        }
    }

    private func isSubfolderOfOpenFolder(_ url: URL) -> Bool {
        for (_, subfolders) in subfoldersByOpenFolder {
            if subfolders.contains(url) {
                return true
            }
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

    private func refreshPendingStatusBatch(for urls: [URL]) {
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
                    try? fileManager.moveItem(at: xmpSource, to: xmpDestination)
                }

                try? sidecarService.moveSidecar(for: url, from: folderURL, to: destinationFolder)

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

    private func presentMoveErrorAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Move Failed"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Manual Sort

    func initializeManualOrder(from currentSorted: [ImageFile]) {
        manualOrder = currentSorted.map(\.url)
    }

    enum SortOrder: String, CaseIterable {
        case name = "Name"
        case dateModified = "Date Modified"
        case rating = "Rating"
        case label = "Label"
        case fileType = "File Type"
        case manual = "Manual"
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
}
