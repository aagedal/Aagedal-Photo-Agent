import AppKit
import Observation

/// NSViewController managing the NSCollectionView with a diffable data source.
final class CollectionViewGridController: NSViewController, NSCollectionViewDelegateFlowLayout, NSCollectionViewPrefetching {

    enum Section { case main }

    let viewModel: BrowserViewModel
    /// Called when the user clicks into this grid — split-view container uses it to
    /// mark the pane active.
    var onFocus: (() -> Void)?
    private var collectionView: ThumbnailCollectionView!
    private var dataSource: NSCollectionViewDiffableDataSource<Section, URL>!
    private var observationTasks: [Task<Void, Never>] = []
    private var lastSnapshotURLs: [URL] = []
    private var lastImageStates: [URL: ImageFile] = [:]
    /// In-flight speculative prefetch tasks, keyed by URL so `cancelPrefetchingForItemsAt` can
    /// actually stop work for items the user scrolled past before their decode started.
    private var prefetchTasks: [URL: Task<Void, Never>] = [:]

    private let baseMinWidth: CGFloat = 190
    /// Horizontal gap between thumbnails. Cells fill the row exactly, so this is the actual
    /// gap (not just a floor the layout pads out unevenly).
    private let interitemSpacing: CGFloat = 3
    /// Vertical gap between rows (a touch larger, since each row has a label strip below it).
    private let lineSpacing: CGFloat = 8
    private let gridPadding: CGFloat = 8
    /// Matches ThumbnailItemView's internal padding and label area, so cell-height math lines up.
    private let cellInnerPadding: CGFloat = 6
    private let baseImageHeight: CGFloat = 140
    private let textAreaHeight: CGFloat = 44
    /// Last width we reflowed at, so `viewDidLayout` only re-lays-out on real width changes.
    private var lastLayoutWidth: CGFloat = 0

    init(viewModel: BrowserViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    deinit {
        for task in observationTasks {
            task.cancel()
        }
    }

    // MARK: - View Lifecycle

    override func loadView() {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        collectionView = ThumbnailCollectionView()
        collectionView.viewModel = viewModel
        collectionView.onFocus = { [weak self] in self?.onFocus?() }
        collectionView.isSelectable = false // We handle selection ourselves
        collectionView.backgroundColors = [.clear]
        collectionView.prefetchDataSource = self

        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = interitemSpacing
        layout.minimumLineSpacing = lineSpacing
        layout.sectionInset = NSEdgeInsets(top: gridPadding, left: gridPadding, bottom: gridPadding, right: gridPadding)
        updateLayoutItemSize(layout, scale: viewModel.thumbnailScale)
        collectionView.collectionViewLayout = layout

        collectionView.register(ThumbnailCollectionViewItem.self, forItemWithIdentifier: ThumbnailCollectionViewItem.identifier)

        scrollView.documentView = collectionView

        self.view = scrollView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupDataSource()
        startObservation()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Make collection view first responder for keyboard events
        view.window?.makeFirstResponder(collectionView)
    }

    // MARK: - Data Source

    private func setupDataSource() {
        dataSource = NSCollectionViewDiffableDataSource<Section, URL>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, url -> NSCollectionViewItem? in
            guard let self else { return nil }
            let item = collectionView.makeItem(
                withIdentifier: ThumbnailCollectionViewItem.identifier,
                for: indexPath
            ) as? ThumbnailCollectionViewItem
            guard let item else { return nil }

            self.configureItem(item, at: indexPath, url: url)
            return item
        }
    }

    private func configureItem(_ item: ThumbnailCollectionViewItem, at indexPath: IndexPath, url: URL) {
        guard indexPath.item < viewModel.visibleImages.count else { return }
        let imageFile = viewModel.visibleImages[indexPath.item]
        guard imageFile.url == url else { return }

        let data = ThumbnailCellData(from: imageFile)
        let isSelected = viewModel.selectedImageIDs.contains(url)
        let isActive = isSelected && url == viewModel.lastClickedImageURL

        item.configure(
            with: data,
            thumbnailService: viewModel.thumbnailService,
            showOriginals: viewModel.showOriginalThumbnails,
            imageFile: imageFile,
            isSelected: isSelected,
            isActive: isActive
        )
        item.thumbnailView.onAccessibilityPress = { [weak self] in
            self?.selectItemFromAccessibility(url)
        }
        item.thumbnailView.updateScale(viewModel.thumbnailScale)
    }

    private func selectItemFromAccessibility(_ url: URL) {
        onFocus?()
        viewModel.selectedImageIDs = [url]
        viewModel.lastClickedImageURL = url
        updateVisibleSelections(selectedIDs: [url], lastClicked: url)
        view.window?.makeFirstResponder(collectionView)
    }

    // MARK: - Observation

    private func startObservation() {
        // 1. Data loop — watch visibleImages and showOriginalThumbnails
        observationTasks.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let (images, _) = await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.viewModel.visibleImages
                        _ = self.viewModel.showOriginalThumbnails
                    } onChange: {
                        Task { @MainActor [weak self] in
                            guard let self else {
                                continuation.resume(returning: ([] as [ImageFile], false))
                                return
                            }
                            continuation.resume(returning: (self.viewModel.visibleImages, self.viewModel.showOriginalThumbnails))
                        }
                    }
                }
                guard !Task.isCancelled else { return }
                self.applyDataUpdate(images: images)
            }
        })

        // 2. Selection loop — watch selectedImageIDs and lastClickedImageURL
        // Uses lightweight DispatchQueue.main.async instead of Task continuations
        // to minimize latency. Direct calls from ThumbnailCollectionView handle
        // keyboard/mouse changes; this catches external selection changes (menus, etc.)
        observeSelection()

        // 3. Layout loop — watch thumbnailScale
        observationTasks.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let scale = await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.viewModel.thumbnailScale
                    } onChange: {
                        Task { @MainActor [weak self] in
                            guard let self else {
                                continuation.resume(returning: 1.0)
                                return
                            }
                            continuation.resume(returning: self.viewModel.thumbnailScale)
                        }
                    }
                }
                guard !Task.isCancelled else { return }
                self.updateLayout(scale: scale)
            }
        })

        // 4. Focus loop — watch shouldRestoreGridFocus
        observationTasks.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let shouldRestore = await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.viewModel.shouldRestoreGridFocus
                    } onChange: {
                        Task { @MainActor [weak self] in
                            guard let self else {
                                continuation.resume(returning: false)
                                return
                            }
                            continuation.resume(returning: self.viewModel.shouldRestoreGridFocus)
                        }
                    }
                }
                guard !Task.isCancelled, shouldRestore else { continue }
                self.view.window?.makeFirstResponder(self.collectionView)
                self.viewModel.shouldRestoreGridFocus = false
            }
        })

        // Trigger initial data load
        applyDataUpdate(images: viewModel.visibleImages)
    }

    /// Lightweight observation for selection changes from external sources (menus, notifications).
    /// Re-registers itself after each change via DispatchQueue.main.async for minimal latency.
    private func observeSelection() {
        withObservationTracking {
            _ = self.viewModel.selectedImageIDs
            _ = self.viewModel.lastClickedImageURL
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateVisibleSelections(
                    selectedIDs: self.viewModel.selectedImageIDs,
                    lastClicked: self.viewModel.lastClickedImageURL
                )
                self.observeSelection() // Re-register
            }
        }
    }

    // MARK: - Data Updates

    private func applyDataUpdate(images: [ImageFile]) {
        let newURLs = images.map(\.url)
        let newStates = Dictionary(uniqueKeysWithValues: images.map { ($0.url, $0) })

        // Find items that changed properties (need reconfigure, not insert/delete)
        var changedURLs: [URL] = []
        for image in images {
            if let old = lastImageStates[image.url], old != image {
                changedURLs.append(image.url)
            }
        }

        var snapshot = NSDiffableDataSourceSnapshot<Section, URL>()
        snapshot.appendSections([.main])
        snapshot.appendItems(newURLs, toSection: .main)

        if !changedURLs.isEmpty {
            snapshot.reloadItems(changedURLs)
        }

        let isStructuralChange = newURLs != lastSnapshotURLs
        // Only animate when items are added/removed, not when just reordered (sort change).
        // Animating reorder of hundreds of items causes layout thrashing and constraint conflicts.
        let itemsAddedOrRemoved = isStructuralChange && Set(newURLs) != Set(lastSnapshotURLs)
        dataSource.apply(snapshot, animatingDifferences: itemsAddedOrRemoved)

        lastSnapshotURLs = newURLs
        lastImageStates = newStates
    }

    // MARK: - Selection Updates

    private func updateVisibleSelections(selectedIDs: Set<URL>, lastClicked: URL?) {
        for item in collectionView.visibleItems() {
            guard let thumbnailItem = item as? ThumbnailCollectionViewItem,
                  let indexPath = collectionView.indexPath(for: item),
                  indexPath.item < viewModel.visibleImages.count else { continue }
            let url = viewModel.visibleImages[indexPath.item].url
            let isSelected = selectedIDs.contains(url)
            let isActive = isSelected && url == lastClicked
            thumbnailItem.thumbnailView.updateSelection(isSelected: isSelected, isActive: isActive)
        }

        // Scroll to last clicked if needed
        if let lastClicked, let index = viewModel.urlToVisibleIndex[lastClicked] {
            let indexPath = IndexPath(item: index, section: 0)
            collectionView.scrollToItemIfNeeded(at: indexPath)
        }
    }

    // MARK: - Layout Updates

    private func updateLayout(scale: Double) {
        guard let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
        updateLayoutItemSize(layout, scale: scale)

        // Update scale on visible cells
        for item in collectionView.visibleItems() {
            (item as? ThumbnailCollectionViewItem)?.thumbnailView.updateScale(scale)
        }

        layout.invalidateLayout()
    }

    private func updateLayoutItemSize(_ layout: NSCollectionViewFlowLayout, scale: Double) {
        let width = collectionView?.bounds.width ?? 0
        layout.itemSize = itemSize(forWidth: width, scale: scale)
        lastLayoutWidth = width
    }

    /// Fill-the-row item size: each cell grows so a row's leftover space is absorbed into the
    /// cells (giving uniform `interitemSpacing` gaps and even edges) instead of NSCollectionView
    /// dumping all of it between items. Height grows with width to preserve the image-box aspect.
    private func itemSize(forWidth containerWidth: CGFloat, scale: Double) -> NSSize {
        let target = baseMinWidth * scale
        let available = max(containerWidth - gridPadding * 2, target)
        let columns = max(1, Int((available + interitemSpacing) / (target + interitemSpacing)))
        let itemWidth = ((available - interitemSpacing * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down)
        let innerWidth = itemWidth - cellInnerPadding * 2
        let boxAspect = (baseMinWidth - cellInnerPadding * 2) / baseImageHeight
        let imageHeight = innerWidth / boxAspect
        let itemHeight = (imageHeight + cellInnerPadding + textAreaHeight).rounded()
        return NSSize(width: itemWidth, height: itemHeight)
    }

    // MARK: - Reflow on width change (window resize, split-divider drag, sidebar toggle)

    override func viewDidLayout() {
        super.viewDidLayout()
        guard let layout = collectionView?.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
        let width = collectionView.bounds.width
        guard abs(width - lastLayoutWidth) > 0.5 else { return }
        lastLayoutWidth = width
        layout.itemSize = itemSize(forWidth: width, scale: viewModel.thumbnailScale)
        layout.invalidateLayout()
    }

    // MARK: - NSCollectionViewDelegateFlowLayout

    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> NSSize {
        itemSize(forWidth: collectionView.bounds.width, scale: viewModel.thumbnailScale)
    }

    // MARK: - NSCollectionViewPrefetching

    func collectionView(_ collectionView: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let service = viewModel.thumbnailService
        let showOriginals = viewModel.showOriginalThumbnails
        for indexPath in indexPaths {
            guard indexPath.item < viewModel.visibleImages.count else { continue }
            let image = viewModel.visibleImages[indexPath.item]
            guard !image.isICloudDownloadPending else { continue }
            let url = image.url
            guard prefetchTasks[url] == nil else { continue }

            let needsOriginal = service.thumbnail(for: url, preferOriginal: showOriginals) == nil
            let settings = image.cameraRawSettings
            let needsEdited = !showOriginals
                && settings?.isEmpty == false
                && !service.hasEditedThumbnail(for: url)
            guard needsOriginal || needsEdited else { continue }
            let orientation = image.exifOrientation

            prefetchTasks[url] = Task { [weak self] in
                if needsOriginal {
                    _ = await service.loadThumbnail(for: url)
                }
                // Pre-render edited thumbnails for images with develop edits, unless the user
                // scrolled this item out of the prefetch window in the meantime.
                if !Task.isCancelled, needsEdited, let settings {
                    _ = await service.renderEditedThumbnail(
                        for: url, settings: settings, exifOrientation: orientation)
                }
                self?.prefetchTasks.removeValue(forKey: url)
            }
        }
    }

    func collectionView(_ collectionView: NSCollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            guard indexPath.item < viewModel.visibleImages.count else { continue }
            let url = viewModel.visibleImages[indexPath.item].url
            prefetchTasks.removeValue(forKey: url)?.cancel()
        }
    }
}
