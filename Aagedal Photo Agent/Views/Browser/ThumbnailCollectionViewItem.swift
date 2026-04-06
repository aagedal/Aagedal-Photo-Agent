import AppKit

/// NSCollectionViewItem subclass managing the lifecycle of a single thumbnail cell.
final class ThumbnailCollectionViewItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ThumbnailCollectionViewItem")

    private(set) var thumbnailView: ThumbnailItemView!
    var thumbnailLoadTask: Task<Void, Never>?
    private var currentURL: URL?

    override func loadView() {
        let itemView = ThumbnailItemView(frame: .zero)
        self.view = itemView
        self.thumbnailView = itemView
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailLoadTask?.cancel()
        thumbnailLoadTask = nil
        currentURL = nil
        thumbnailView.reset()
    }

    func configure(
        with data: ThumbnailCellData,
        thumbnailService: ThumbnailService,
        showOriginals: Bool,
        imageFile: ImageFile,
        isSelected: Bool,
        isActive: Bool
    ) {
        currentURL = data.url
        thumbnailView.configure(with: data)
        thumbnailView.updateSelection(isSelected: isSelected, isActive: isActive)

        thumbnailLoadTask?.cancel()
        let url = data.url
        let needsEditedRender = !showOriginals
            && imageFile.cameraRawSettings?.crop?.isEmpty == false

        // Synchronous cache check — prefer edited unless showOriginals
        if let cached = thumbnailService.thumbnail(for: url, preferOriginal: showOriginals) {
            thumbnailView.setThumbnailNSImage(cached)
            // If we got the original but need the edited version, render it async
            if needsEditedRender, !thumbnailService.hasEditedThumbnail(for: url) {
                let settings = imageFile.cameraRawSettings!
                let orientation = imageFile.exifOrientation
                thumbnailLoadTask = Task { [weak self] in
                    let edited = await thumbnailService.renderEditedThumbnail(
                        for: url, settings: settings, exifOrientation: orientation)
                    guard !Task.isCancelled, let self, self.currentURL == url else { return }
                    if let edited { self.thumbnailView.setThumbnailNSImage(edited) }
                }
            }
            return
        }

        // Async load — original first, then edited if needed
        let settings = needsEditedRender ? imageFile.cameraRawSettings : nil
        let orientation = imageFile.exifOrientation

        thumbnailLoadTask = Task { [weak self] in
            let image = await thumbnailService.loadThumbnail(for: url)
            guard !Task.isCancelled,
                  let self,
                  self.currentURL == url else { return }
            self.thumbnailView.setThumbnailNSImage(image)

            // If this image has a crop, render the cropped thumbnail
            if let settings, settings.crop?.isEmpty == false {
                let edited = await thumbnailService.renderEditedThumbnail(
                    for: url, settings: settings, exifOrientation: orientation)
                guard !Task.isCancelled, self.currentURL == url else { return }
                if let edited { self.thumbnailView.setThumbnailNSImage(edited) }
            }
        }
    }
}
