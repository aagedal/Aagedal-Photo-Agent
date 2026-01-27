import Foundation
import AppKit

@Observable
final class BrowserViewModel {
    var images: [ImageFile] = []
    var selectedImageIDs: Set<URL> = []
    var lastClickedImageURL: URL?
    var currentFolderURL: URL?
    var currentFolderName: String?
    var isLoading = false
    var isFullScreen = false
    var errorMessage: String?
    var sortOrder: SortOrder = .name
    var favoriteFolders: [FavoriteFolder] = []
    var manualOrder: [URL] = []
    var draggedImageURLs: Set<URL> = []

    let fileSystemService = FileSystemService()
    let thumbnailService = ThumbnailService()
    let exifToolService = ExifToolService()

    private let favoritesKey = "favoriteFolders"

    var selectedImages: [ImageFile] {
        images.filter { selectedImageIDs.contains($0.url) }
    }

    var firstSelectedImage: ImageFile? {
        guard let firstID = selectedImageIDs.first else { return nil }
        return images.first { $0.url == firstID }
    }

    var sortedImages: [ImageFile] {
        switch sortOrder {
        case .name:
            return images.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        case .dateModified:
            return images.sorted { $0.dateModified > $1.dateModified }
        case .rating:
            return images.sorted { $0.starRating.rawValue > $1.starRating.rawValue }
        case .label:
            return images.sorted { ($0.colorLabel.shortcutIndex ?? 0) < ($1.colorLabel.shortcutIndex ?? 0) }
        case .fileType:
            return images.sorted {
                let ext0 = $0.url.pathExtension.lowercased()
                let ext1 = $1.url.pathExtension.lowercased()
                if ext0 != ext1 {
                    return ext0.localizedStandardCompare(ext1) == .orderedAscending
                }
                return $0.filename.localizedStandardCompare($1.filename) == .orderedAscending
            }
        case .manual:
            guard !manualOrder.isEmpty else { return images }
            let imagesByURL = Dictionary(uniqueKeysWithValues: images.map { ($0.url, $0) })
            var result = manualOrder.compactMap { imagesByURL[$0] }
            let manualSet = Set(manualOrder)
            result.append(contentsOf: images.filter { !manualSet.contains($0.url) })
            return result
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

    func loadFolder(url: URL) {
        currentFolderURL = url
        currentFolderName = url.lastPathComponent
        isLoading = true
        errorMessage = nil
        selectedImageIDs.removeAll()
        lastClickedImageURL = nil
        manualOrder.removeAll()

        Task {
            do {
                let files = try fileSystemService.scanFolder(at: url)
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
                        // C2PA detection: any JUMBF data present
                        let hasJUMBF = dict.keys.contains { $0.hasPrefix("JUMBF") || $0.contains("JUMBF") }
                        images[index].hasC2PA = hasJUMBF
                    }
                }
            } catch {
                // Continue with next batch
            }
        }
    }

    // MARK: - Arrow Key Navigation

    func selectNext(extending: Bool = false) {
        let sorted = sortedImages
        guard !sorted.isEmpty else { return }
        let anchor = lastClickedImageURL ?? selectedImageIDs.first
        guard let anchorURL = anchor,
              let currentIndex = sorted.firstIndex(where: { $0.url == anchorURL }) else {
            selectedImageIDs = [sorted[0].url]
            lastClickedImageURL = sorted[0].url
            return
        }
        let nextIndex = min(currentIndex + 1, sorted.count - 1)
        let nextURL = sorted[nextIndex].url
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
        let sorted = sortedImages
        guard !sorted.isEmpty else { return }
        let anchor = lastClickedImageURL ?? selectedImageIDs.first
        guard let anchorURL = anchor,
              let currentIndex = sorted.firstIndex(where: { $0.url == anchorURL }) else {
            selectedImageIDs = [sorted[0].url]
            lastClickedImageURL = sorted[0].url
            return
        }
        let prevIndex = max(currentIndex - 1, 0)
        let prevURL = sorted[prevIndex].url
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
