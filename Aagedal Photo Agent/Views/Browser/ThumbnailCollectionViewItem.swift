import AppKit
import Combine

/// NSCollectionViewItem subclass managing the lifecycle of a single thumbnail cell.
final class ThumbnailCollectionViewItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ThumbnailCollectionViewItem")

    private(set) var thumbnailView: ThumbnailItemView!
    var thumbnailLoadTask: Task<Void, Never>?
    private var voiceMemoStatusTask: Task<Void, Never>?
    private var voiceMemoStatusObserver: AnyCancellable?
    private var isICloudDownloadPending = false
    var voiceMemoStatusLoader: @Sendable (URL) async -> CaptionVoiceMemoTranscriptionStatus = {
        await CaptionVoiceMemoStatusService.shared.status(for: $0)
    }
    /// Identity of the image actually represented by this cell. During a diffable
    /// insertion its collection index can still belong to the previous snapshot.
    private(set) var currentURL: URL?

    override func loadView() {
        let itemView = ThumbnailItemView(frame: .zero)
        self.view = itemView
        self.thumbnailView = itemView
        voiceMemoStatusObserver = NotificationCenter.default.publisher(for: MetadataSidecarService.voiceMemoTranscriptDidChange)
            // Notifications arrive on the metadata filesystem queue. Hop before either
            // closure created in this MainActor-isolated view is invoked.
            .receive(on: DispatchQueue.main)
            .compactMap { $0.object as? URL }
            .sink { [weak self] url in
                Task { @MainActor [weak self] in
                    guard let self, self.currentURL?.standardizedFileURL.path == url.standardizedFileURL.path else { return }
                    self.refreshVoiceMemoStatus()
                }
            }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailLoadTask?.cancel()
        thumbnailLoadTask = nil
        voiceMemoStatusTask?.cancel()
        voiceMemoStatusTask = nil
        currentURL = nil
        thumbnailView.reset()
        thumbnailView.setAccessibilityLabel(nil)
        thumbnailView.setAccessibilityValue(nil)
        thumbnailView.setAccessibilityHelp(nil)
    }

    func configure(
        with data: ThumbnailCellData,
        thumbnailService: ThumbnailService,
        showOriginals: Bool,
        imageFile: ImageFile,
        isSelected: Bool,
        isActive: Bool
    ) {
        if currentURL != data.url { thumbnailView.updateVoiceMemoStatus(.none) }
        currentURL = data.url
        isICloudDownloadPending = imageFile.isICloudDownloadPending
        thumbnailView.configure(with: data)
        thumbnailView.updateSelection(isSelected: isSelected, isActive: isActive)
        thumbnailView.setAccessibilityElement(true)
        thumbnailView.setAccessibilityRole(.button)
        thumbnailView.setAccessibilityLabel(imageFile.filename)
        thumbnailView.setAccessibilityHelp(
            "Rating \(imageFile.starRating.rawValue) of 5, \(imageFile.colorLabel.displayName) label. Use arrow keys to navigate and Space to open Full Screen."
        )

        thumbnailLoadTask?.cancel()
        let url = data.url
        refreshVoiceMemoStatus(checkFilesystem: !imageFile.isICloudDownloadPending)
        if imageFile.isICloudDownloadPending {
            thumbnailView.setThumbnailNSImage(nil)
            return
        }

        let needsEditedRender = !showOriginals
            && imageFile.cameraRawSettings?.isEmpty == false

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

            // If this image has develop edits, render the edited thumbnail
            if let settings, !settings.isEmpty {
                let edited = await thumbnailService.renderEditedThumbnail(
                    for: url, settings: settings, exifOrientation: orientation)
                guard !Task.isCancelled, self.currentURL == url else { return }
                if let edited { self.thumbnailView.setThumbnailNSImage(edited) }
            }
        }
    }
    func refreshVoiceMemoStatus(checkFilesystem: Bool = true) {
        voiceMemoStatusTask?.cancel()
        voiceMemoStatusTask = nil
        guard checkFilesystem, !isICloudDownloadPending, let url = currentURL else {
            thumbnailView.updateVoiceMemoStatus(.none)
            return
        }
        let loader = voiceMemoStatusLoader
        voiceMemoStatusTask = Task { [weak self] in
            let status = await loader(url)
            guard !Task.isCancelled, let self, self.currentURL == url else { return }
            self.thumbnailView.updateVoiceMemoStatus(status)
        }
    }

}
