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

    let fileSystemService = FileSystemService()
    let thumbnailService = ThumbnailService()
    let exifToolService = ExifToolService()
    private let sidecarService = MetadataSidecarService()

    private let favoritesKey = "favoriteFolders"

    private(set) var sortedImages: [ImageFile] = []
    private(set) var urlToSortedIndex: [URL: Int] = [:]

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
                        // C2PA detection: look for JUMD/C2PA keys from -JUMBF:All output
                        let hasC2PA = dict.keys.contains { $0.hasPrefix("JUMD") || $0.hasPrefix("C2PA") || $0 == "Claim_generator" }
                        images[index].hasC2PA = hasC2PA
                    }
                }
            } catch {
                // Continue with next batch
            }
        }
    }

    // MARK: - Arrow Key Navigation

    func selectNext(extending: Bool = false) {
        guard !sortedImages.isEmpty else { return }
        let anchor = lastClickedImageURL ?? selectedImageIDs.first
        guard let anchorURL = anchor,
              let currentIndex = urlToSortedIndex[anchorURL] else {
            selectedImageIDs = [sortedImages[0].url]
            lastClickedImageURL = sortedImages[0].url
            return
        }
        let nextIndex = min(currentIndex + 1, sortedImages.count - 1)
        let nextURL = sortedImages[nextIndex].url
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
        guard !sortedImages.isEmpty else { return }
        let anchor = lastClickedImageURL ?? selectedImageIDs.first
        guard let anchorURL = anchor,
              let currentIndex = urlToSortedIndex[anchorURL] else {
            selectedImageIDs = [sortedImages[0].url]
            lastClickedImageURL = sortedImages[0].url
            return
        }
        let prevIndex = max(currentIndex - 1, 0)
        let prevURL = sortedImages[prevIndex].url
        if extending {
            var updated = selectedImageIDs
            updated.insert(prevURL)
            selectedImageIDs = updated
        } else {
            selectedImageIDs = [prevURL]
        }
        lastClickedImageURL = prevURL
    }

    // MARK: - Rating & Labels

    func setRating(_ rating: StarRating) {
        guard !selectedImageIDs.isEmpty else { return }
        let urls = selectedImages.map(\.url)

        for id in selectedImageIDs {
            if let index = images.firstIndex(where: { $0.url == id }) {
                images[index].starRating = rating
            }
        }

        guard exifToolService.isAvailable else { return }
        Task {
            try? await exifToolService.writeRating(rating, to: urls)
        }
    }

    func setLabel(_ label: ColorLabel) {
        guard !selectedImageIDs.isEmpty else { return }
        let urls = selectedImages.map(\.url)

        for id in selectedImageIDs {
            if let index = images.firstIndex(where: { $0.url == id }) {
                images[index].colorLabel = label
            }
        }

        guard exifToolService.isAvailable else { return }
        Task {
            try? await exifToolService.writeLabel(label, to: urls)
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
}
