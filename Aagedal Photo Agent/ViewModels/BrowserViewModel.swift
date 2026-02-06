import Foundation
import AppKit
import os

@Observable
final class BrowserViewModel {
    var images: [ImageFile] = [] {
        didSet {
            urlToImageIndex = Dictionary(uniqueKeysWithValues: images.enumerated().map { ($1.url, $0) })
            rebuildSortedCache()
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

    struct FullScreenFaceContext {
        let faceRecognitionViewModel: FaceRecognitionViewModel
        let highlightedFaceID: UUID?
        let navigationImageURLs: [URL]?
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

    private(set) var selectedImagesCache: [ImageFile] = []

    init() {
        if let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.thumbnailSortOrder),
           let stored = SortOrder(rawValue: raw) {
            sortOrder = stored
        }
    }

    var selectedImages: [ImageFile] { selectedImagesCache }

    var firstSelectedImage: ImageFile? {
        guard let firstID = selectedImageIDs.first else { return nil }
        if let index = urlToImageIndex[firstID] { return images[index] }
        return nil
    }

    private func rebuildSortedCache() {
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
            if image.filename.lowercased().contains(query) {
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

        // Process in batches
        let batchSize = 50
        let urls = images.map(\.url)

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
                            images[index].starRating = starRating
                        }
                        images[index].colorLabel = ColorLabel.fromMetadataLabel(dict[ExifToolReadKey.label] as? String)
                        images[index].personShown = parseStringOrArray(dict[ExifToolReadKey.personInImage])
                        // C2PA detection: look for JUMD/C2PA keys from -JUMBF:All output
                        let hasC2PA = TechnicalMetadata.dictHasC2PA(dict)
                        images[index].hasC2PA = hasC2PA
                        applyPendingSidecarOverrides(for: sourceURL, index: index, cachedSidecar: cachedSidecars[sourceURL])
                    }
                }
            } catch {
                logger.warning("Batch metadata load failed (batch at offset \(batchStart)): \(error.localizedDescription)")
            }
        }
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
                            images[index].starRating = starRating
                        }
                        images[index].colorLabel = ColorLabel.fromMetadataLabel(dict[ExifToolReadKey.label] as? String)
                        images[index].personShown = parseStringOrArray(dict[ExifToolReadKey.personInImage])
                        let hasC2PA = TechnicalMetadata.dictHasC2PA(dict)
                        images[index].hasC2PA = hasC2PA
                        applyPendingSidecarOverrides(for: sourceURL, index: index)
                    }
                }
            } catch {
                logger.warning("Incremental metadata load failed: \(error.localizedDescription)")
            }
        }
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

    // MARK: - Arrow Key Navigation

    @discardableResult
    private func navigateFullScreenFaceSequence(step: Int) -> Bool {
        guard isFullScreen,
              let navigationURLs = fullScreenFaceContext?.navigationImageURLs,
              !navigationURLs.isEmpty else {
            return false
        }

        let anchor = selectedImageIDs.first ?? lastClickedImageURL
        guard let anchorURL = anchor,
              let currentIndex = navigationURLs.firstIndex(of: anchorURL) else {
            let firstURL = navigationURLs[0]
            selectedImageIDs = [firstURL]
            lastClickedImageURL = firstURL
            return true
        }

        let targetIndex = max(0, min(currentIndex + step, navigationURLs.count - 1))
        let targetURL = navigationURLs[targetIndex]
        selectedImageIDs = [targetURL]
        lastClickedImageURL = targetURL
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
        guard !selectedImageIDs.isEmpty else { return }
        let urls = selectedImages.map(\.url)
        let lookup = Dictionary(uniqueKeysWithValues: images.map { ($0.url, $0) })

        for id in selectedImageIDs {
            if let index = urlToImageIndex[id] {
                images[index].starRating = rating
            }
        }

        Task {
            var writeToFile: [URL] = []
            var writeToSidecar: [URL] = []
            var writeToXmp: [URL] = []

            for url in urls {
                let hasC2PA = lookup[url]?.hasC2PA ?? false
                let mode = MetadataWriteMode.current(forC2PA: hasC2PA)

                switch mode {
                case .historyOnly:
                    writeToSidecar.append(url)
                case .writeToXMPSidecar:
                    writeToXmp.append(url)
                case .writeToFile:
                    writeToFile.append(url)
                }
            }

            for url in writeToSidecar {
                await applyRatingToSidecar(url: url, rating: rating, writeXmpSidecar: false, pendingChanges: true)
            }
            for url in writeToXmp {
                await applyRatingToSidecar(url: url, rating: rating, writeXmpSidecar: true, pendingChanges: false)
            }
            for url in writeToFile {
                await applyRatingToSidecar(url: url, rating: rating, writeXmpSidecar: false, pendingChanges: false)
            }

            if exifToolService.isAvailable, !writeToFile.isEmpty {
                do {
                    try await exifToolService.writeRating(rating, to: writeToFile)
                } catch {
                    self.errorMessage = "Failed to write rating: \(error.localizedDescription)"
                }
            }

            await MainActor.run {
                self.refreshPendingStatus()
            }
        }
    }

    func setLabel(_ label: ColorLabel) {
        guard !selectedImageIDs.isEmpty else { return }
        let urls = selectedImages.map(\.url)
        let lookup = Dictionary(uniqueKeysWithValues: images.map { ($0.url, $0) })

        for id in selectedImageIDs {
            if let index = urlToImageIndex[id] {
                images[index].colorLabel = label
            }
        }

        Task {
            var writeToFile: [URL] = []
            var writeToSidecar: [URL] = []
            var writeToXmp: [URL] = []

            for url in urls {
                let hasC2PA = lookup[url]?.hasC2PA ?? false
                let mode = MetadataWriteMode.current(forC2PA: hasC2PA)

                switch mode {
                case .historyOnly:
                    writeToSidecar.append(url)
                case .writeToXMPSidecar:
                    writeToXmp.append(url)
                case .writeToFile:
                    writeToFile.append(url)
                }
            }

            for url in writeToSidecar {
                await applyLabelToSidecar(url: url, label: label, writeXmpSidecar: false, pendingChanges: true)
            }
            for url in writeToXmp {
                await applyLabelToSidecar(url: url, label: label, writeXmpSidecar: true, pendingChanges: false)
            }
            for url in writeToFile {
                await applyLabelToSidecar(url: url, label: label, writeXmpSidecar: false, pendingChanges: false)
            }

            if exifToolService.isAvailable, !writeToFile.isEmpty {
                do {
                    try await exifToolService.writeLabel(label, to: writeToFile)
                } catch {
                    self.errorMessage = "Failed to write label: \(error.localizedDescription)"
                }
            }

            await MainActor.run {
                self.refreshPendingStatus()
            }
        }
    }

    private func applyPendingSidecarOverrides(for url: URL, index: Int, cachedSidecar: MetadataSidecar? = nil) {
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
                images[index].starRating = StarRating(rawValue: ratingValue) ?? .none
            }
            if sidecar.metadata.label != snapshot.label {
                images[index].colorLabel = ColorLabel.fromMetadataLabel(sidecar.metadata.label)
            }
        } else {
            if let ratingValue = sidecar.metadata.rating {
                images[index].starRating = StarRating(rawValue: ratingValue) ?? .none
            }
            images[index].colorLabel = ColorLabel.fromMetadataLabel(sidecar.metadata.label)
        }
    }

    private func applyRatingToSidecar(url: URL, rating: StarRating, writeXmpSidecar: Bool, pendingChanges: Bool) async {
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

        let oldValue = metadata.rating
        metadata.rating = rating == .none ? nil : rating.rawValue
        let newValue = metadata.rating

        guard oldValue != newValue else { return }

        history.append(MetadataHistoryEntry(
            timestamp: Date(),
            fieldName: "Rating",
            oldValue: oldValue.map(String.init),
            newValue: newValue.map(String.init)
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

    private func applyLabelToSidecar(url: URL, label: ColorLabel, writeXmpSidecar: Bool, pendingChanges: Bool) async {
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

        let oldValue = metadata.label
        metadata.label = label.xmpLabelValue
        let newValue = metadata.label

        guard oldValue != newValue else { return }

        history.append(MetadataHistoryEntry(
            timestamp: Date(),
            fieldName: "Label",
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
            if (includeXmp || preferXmp), let xmpMetadata = xmpSidecarService.loadSidecar(for: url) {
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
        return names
    }

    func refreshPendingStatus() {
        guard let folderURL = currentFolderURL else { return }
        let allSidecars = sidecarService.loadAllSidecars(in: folderURL)
        for i in images.indices {
            if let sidecar = allSidecars[images[i].url], sidecar.pendingChanges {
                images[i].hasPendingMetadataChanges = true
                images[i].pendingFieldNames = extractPendingFieldNames(from: sidecar)
            } else {
                images[i].hasPendingMetadataChanges = false
                images[i].pendingFieldNames = []
            }
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
