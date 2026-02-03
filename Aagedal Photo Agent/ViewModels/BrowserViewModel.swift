import Foundation
import AppKit

@Observable
final class BrowserViewModel {
    var images: [ImageFile] = [] {
        didSet { rebuildSortedCache() }
    }
    var selectedImageIDs: Set<URL> = []
    var lastClickedImageURL: URL?
    var currentFolderURL: URL?
    var currentFolderName: String?
    var isLoading = false
    var isFullScreen = false
    var errorMessage: String?
    var sortOrder: SortOrder = .name {
        didSet { rebuildSortedCache() }
    }
    var favoriteFolders: [FavoriteFolder] = []
    var openFolders: [URL] = []
    var manualOrder: [URL] = [] {
        didSet {
            if sortOrder == .manual { rebuildSortedCache() }
        }
    }
    var draggedImageURLs: Set<URL> = []
    var searchText: String = "" {
        didSet { rebuildVisibleCache() }
    }
    var minimumStarRating: StarRating = .none {
        didSet { rebuildVisibleCache() }
    }
    var selectedColorLabels: Set<ColorLabel> = [] {
        didSet { rebuildVisibleCache() }
    }
    var personShownFilter: PersonShownFilter = .any {
        didSet { rebuildVisibleCache() }
    }

    let fileSystemService = FileSystemService()
    let thumbnailService = ThumbnailService()
    let exifToolService = ExifToolService()
    private let sidecarService = MetadataSidecarService()
    private let xmpSidecarService = XMPSidecarService()

    @ObservationIgnored var onImagesDeleted: ((Set<URL>) -> Void)?

    private let favoritesKey = "favoriteFolders"

    private(set) var sortedImages: [ImageFile] = []
    private(set) var urlToSortedIndex: [URL: Int] = [:]
    private(set) var visibleImages: [ImageFile] = []
    private(set) var urlToVisibleIndex: [URL: Int] = [:]

    var isFilteringActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || minimumStarRating != .none
            || !selectedColorLabels.isEmpty
            || personShownFilter != .any
    }

    var selectedImages: [ImageFile] {
        images.filter { selectedImageIDs.contains($0.url) }
    }

    var firstSelectedImage: ImageFile? {
        guard let firstID = selectedImageIDs.first else { return nil }
        return images.first { $0.url == firstID }
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

    private func rebuildVisibleCache() {
        let filtered = applyFilters(to: sortedImages)
        visibleImages = filtered
        urlToVisibleIndex = Dictionary(uniqueKeysWithValues: filtered.enumerated().map { ($1.url, $0) })

        let visibleSet = Set(filtered.map(\.url))
        if !selectedImageIDs.isEmpty {
            selectedImageIDs = selectedImageIDs.intersection(visibleSet)
        }
        if let anchor = lastClickedImageURL, !visibleSet.contains(anchor) {
            lastClickedImageURL = nil
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

        // Add to open folders if not already there
        if !openFolders.contains(url) {
            openFolders.append(url)
        }

        Task {
            do {
                var files = try fileSystemService.scanFolder(at: url)
                let pendingURLs = sidecarService.imagesWithPendingChanges(in: url)
                for i in files.indices {
                    if pendingURLs.contains(files[i].url) {
                        files[i].hasPendingMetadataChanges = true
                        files[i].pendingFieldNames = sidecarService.pendingFieldNames(for: files[i].url, in: url)
                    }
                }
                self.images = files
                self.isLoading = false
                await loadBasicMetadata()
            } catch {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    private func loadBasicMetadata() async {
        guard exifToolService.isAvailable else { return }

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
                    guard let sourcePath = dict["SourceFile"] as? String else { continue }
                    let sourceURL = URL(fileURLWithPath: sourcePath)

                    if let index = images.firstIndex(where: { $0.url == sourceURL }) {
                        if let rating = dict["Rating"] as? Int,
                           let starRating = StarRating(rawValue: rating) {
                            images[index].starRating = starRating
                        }
                        if let label = dict["Label"] as? String,
                           let colorLabel = ColorLabel(rawValue: label) {
                            images[index].colorLabel = colorLabel
                        }
                        images[index].personShown = parseStringOrArray(dict["PersonInImage"])
                        // C2PA detection: look for JUMD/C2PA keys from -JUMBF:All output
                        let hasC2PA = dict.keys.contains { $0.hasPrefix("JUMD") || $0.hasPrefix("C2PA") || $0 == "Claim_generator" }
                        images[index].hasC2PA = hasC2PA
                        applyPendingSidecarOverrides(for: sourceURL, index: index)
                    }
                }
            } catch {
                // Continue with next batch
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

    // MARK: - Arrow Key Navigation

    func selectNext(extending: Bool = false) {
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
            for i in (currentIndex + 1)...targetIndex {
                updated.insert(visibleImages[i].url)
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
            for i in targetIndex..<currentIndex {
                updated.insert(visibleImages[i].url)
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
            if let index = images.firstIndex(where: { $0.url == id }) {
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
                try? await exifToolService.writeRating(rating, to: writeToFile)
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
            if let index = images.firstIndex(where: { $0.url == id }) {
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
                try? await exifToolService.writeLabel(label, to: writeToFile)
            }

            await MainActor.run {
                self.refreshPendingStatus()
            }
        }
    }

    private func applyPendingSidecarOverrides(for url: URL, index: Int) {
        guard let folderURL = currentFolderURL,
              let sidecar = sidecarService.loadSidecar(for: url, in: folderURL),
              sidecar.pendingChanges else { return }

        if let snapshot = sidecar.imageMetadataSnapshot {
            if sidecar.metadata.rating != snapshot.rating {
                let ratingValue = sidecar.metadata.rating ?? 0
                images[index].starRating = StarRating(rawValue: ratingValue) ?? .none
            }
            if sidecar.metadata.label != snapshot.label {
                let labelValue = sidecar.metadata.label ?? ""
                images[index].colorLabel = ColorLabel(rawValue: labelValue) ?? .none
            }
        } else {
            if let ratingValue = sidecar.metadata.rating {
                images[index].starRating = StarRating(rawValue: ratingValue) ?? .none
            }
            if let labelValue = sidecar.metadata.label {
                images[index].colorLabel = ColorLabel(rawValue: labelValue) ?? .none
            }
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

        try? sidecarService.saveSidecar(sidecar, for: url, in: folderURL)

        if writeXmpSidecar {
            try? xmpSidecarService.saveSidecar(metadata: metadata, for: url)
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
        metadata.label = label == .none ? nil : label.rawValue
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

        try? sidecarService.saveSidecar(sidecar, for: url, in: folderURL)

        if writeXmpSidecar {
            try? xmpSidecarService.saveSidecar(metadata: metadata, for: url)
        }
    }

    private func loadMetadataSnapshot(for url: URL, includeXmp: Bool) async -> IPTCMetadata? {
        do {
            var metadata = try await exifToolService.readFullMetadata(url: url)
            let preferXmp = UserDefaults.standard.bool(forKey: "metadataPreferXMPSidecar")
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
        openFolders.removeAll { $0 == url }
        // If we closed the current folder, switch to another open folder or clear
        if currentFolderURL == url {
            if let nextFolder = openFolders.first {
                loadFolder(url: nextFolder)
            } else {
                currentFolderURL = nil
                currentFolderName = nil
                images = []
                selectedImageIDs.removeAll()
            }
        }
    }

    // MARK: - Pending Status

    func refreshPendingStatus() {
        guard let folderURL = currentFolderURL else { return }
        let pendingURLs = sidecarService.imagesWithPendingChanges(in: folderURL)
        for i in images.indices {
            let hasPending = pendingURLs.contains(images[i].url)
            images[i].hasPendingMetadataChanges = hasPending
            if hasPending {
                images[i].pendingFieldNames = sidecarService.pendingFieldNames(for: images[i].url, in: folderURL)
            } else {
                images[i].pendingFieldNames = []
            }
        }
    }

    func updatePendingStatus(for url: URL, hasPending: Bool) {
        if let index = images.firstIndex(where: { $0.url == url }) {
            images[index].hasPendingMetadataChanges = hasPending
        }
    }

    // MARK: - Delete

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
