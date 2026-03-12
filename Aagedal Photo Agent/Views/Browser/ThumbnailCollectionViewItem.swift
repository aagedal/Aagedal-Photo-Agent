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
        renderEdits: Bool,
        imageFile: ImageFile,
        isSelected: Bool,
        isActive: Bool
    ) {
        currentURL = data.url
        thumbnailView.configure(with: data)
        thumbnailView.updateSelection(isSelected: isSelected, isActive: isActive)

        // Synchronous cache check
        if let cached = thumbnailService.thumbnail(for: data.url) {
            thumbnailView.setThumbnailNSImage(cached)
            return
        }

        // Async load
        thumbnailLoadTask?.cancel()
        let url = data.url
        let settings = renderEdits ? imageFile.cameraRawSettings : nil
        let orientation = imageFile.exifOrientation

        thumbnailLoadTask = Task { [weak self] in
            let image = await thumbnailService.loadThumbnail(
                for: url,
                cameraRawSettings: settings,
                exifOrientation: orientation
            )
            guard !Task.isCancelled,
                  let self,
                  self.currentURL == url else { return }
            self.thumbnailView.setThumbnailNSImage(image)
        }
    }
}
