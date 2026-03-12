import AppKit
import Observation

/// NSViewController managing the face group NSCollectionView with diffable data source and observation.
final class FaceGroupCollectionController: NSViewController, NSCollectionViewDelegateFlowLayout {

    enum Section { case main }

    enum FaceGroupItem: Hashable {
        case group(UUID)
        case newGroupTarget
    }

    enum NavigationDirection {
        case left, right, up, down
    }

    // MARK: - Dependencies

    let viewModel: FaceRecognitionViewModel
    let selectionState: FaceSelectionState
    let settingsViewModel: SettingsViewModel
    var callbacks = FaceGroupCardCallbacks()

    // MARK: - State

    private(set) var expandedGroupIDs: Set<UUID> = []
    private var collectionView: FaceGroupCollectionView!
    private var dataSource: NSCollectionViewDiffableDataSource<Section, FaceGroupItem>!
    private var observationTasks: [Task<Void, Never>] = []
    private var lastSnapshotGroupIDs: [UUID] = []
    private var lastGroupStates: [UUID: GroupState] = [:]

    private let maxVisibleFaces = 12
    private let minCardWidth: CGFloat = 300
    private let cardSpacing: CGFloat = 16
    private let gridPadding: CGFloat = 16

    /// Lightweight snapshot of group properties for change detection.
    private struct GroupState: Equatable {
        let name: String?
        let faceCount: Int
        let representativeFaceID: UUID
    }

    // MARK: - Init

    init(viewModel: FaceRecognitionViewModel, selectionState: FaceSelectionState, settingsViewModel: SettingsViewModel) {
        self.viewModel = viewModel
        self.selectionState = selectionState
        self.settingsViewModel = settingsViewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
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

        collectionView = FaceGroupCollectionView()
        collectionView.controller = self
        collectionView.isSelectable = false
        collectionView.backgroundColors = [.clear]

        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = cardSpacing
        layout.minimumLineSpacing = cardSpacing
        layout.sectionInset = NSEdgeInsets(top: gridPadding, left: gridPadding, bottom: gridPadding, right: gridPadding)
        collectionView.collectionViewLayout = layout

        collectionView.register(FaceGroupCardItem.self, forItemWithIdentifier: FaceGroupCardItem.identifier)
        collectionView.register(FaceGroupNewGroupItem.self, forItemWithIdentifier: FaceGroupNewGroupItem.identifier)

        // Register as drop target
        collectionView.registerForDraggedTypes([.string])
        collectionView.setDraggingSourceOperationMask(.move, forLocal: true)

        scrollView.documentView = collectionView
        self.view = scrollView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.delegate = self
        setupDataSource()
        startObservation()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(collectionView)
    }

    // MARK: - Column Count

    private func columnCount(for width: CGFloat) -> Int {
        let available = width - gridPadding * 2
        let count = Int((available + cardSpacing) / (minCardWidth + cardSpacing))
        return max(1, count)
    }

    private func cardWidth(for boundsWidth: CGFloat) -> CGFloat {
        let cols = CGFloat(columnCount(for: boundsWidth))
        let available = boundsWidth - gridPadding * 2 - cardSpacing * (cols - 1)
        return max(minCardWidth, available / cols)
    }

    // MARK: - Data Source

    private func setupDataSource() {
        dataSource = NSCollectionViewDiffableDataSource<Section, FaceGroupItem>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, item -> NSCollectionViewItem? in
            guard let self else { return nil }

            switch item {
            case .group(let groupID):
                let cell = collectionView.makeItem(
                    withIdentifier: FaceGroupCardItem.identifier,
                    for: indexPath
                ) as? FaceGroupCardItem
                guard let cell else { return nil }

                if let group = self.viewModel.group(byID: groupID) {
                    // Merge external callbacks with internal expand handler
                    var cardCallbacks = self.callbacks
                    cardCallbacks.onToggleExpand = { [weak self] gid in
                        self?.toggleExpand(groupID: gid)
                    }
                    cell.configure(
                        group: group,
                        viewModel: self.viewModel,
                        selectionState: self.selectionState,
                        settingsViewModel: self.settingsViewModel,
                        isExpanded: self.expandedGroupIDs.contains(groupID),
                        callbacks: cardCallbacks
                    )
                }
                return cell

            case .newGroupTarget:
                let cell = collectionView.makeItem(
                    withIdentifier: FaceGroupNewGroupItem.identifier,
                    for: indexPath
                ) as? FaceGroupNewGroupItem
                return cell
            }
        }
    }

    // MARK: - Observation

    private func startObservation() {
        // 1. Data loop — watch sortedGroups and faceData
        observationTasks.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                _ = await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.viewModel.sortedGroups
                        _ = self.viewModel.faceData
                        _ = self.viewModel.sortMode
                    } onChange: {
                        Task { @MainActor in
                            continuation.resume(returning: ())
                        }
                    }
                }
                guard !Task.isCancelled else { return }
                self.applyDataUpdate()
            }
        })

        // 2. Selection loop — lightweight DispatchQueue.main.async
        observeSelection()

        // Trigger initial data load
        applyDataUpdate()
    }

    private func observeSelection() {
        withObservationTracking {
            _ = self.selectionState.selectedFaceIDs
            _ = self.selectionState.focusedFaceID
            _ = self.selectionState.draggedFaceIDs
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.collectionView.refreshVisibleSelections()
                self.observeSelection()
            }
        }
    }

    // MARK: - Data Updates

    private func applyDataUpdate() {
        let groups = viewModel.sortedGroups
        let newGroupIDs = groups.map(\.id)
        let newStates = Dictionary(uniqueKeysWithValues: groups.map { g in
            (g.id, GroupState(name: g.name, faceCount: g.faceIDs.count, representativeFaceID: g.representativeFaceID))
        })

        // Find changed groups (property changes requiring reconfigure)
        var changedIDs: [FaceGroupItem] = []
        for group in groups {
            if let old = lastGroupStates[group.id],
               old != newStates[group.id] {
                changedIDs.append(.group(group.id))
            }
        }

        var snapshot = NSDiffableDataSourceSnapshot<Section, FaceGroupItem>()
        snapshot.appendSections([.main])
        snapshot.appendItems(newGroupIDs.map { .group($0) }, toSection: .main)
        snapshot.appendItems([.newGroupTarget], toSection: .main)

        if !changedIDs.isEmpty {
            snapshot.reloadItems(changedIDs)
        }

        let isStructuralChange = newGroupIDs != lastSnapshotGroupIDs
        let itemsAddedOrRemoved = isStructuralChange && Set(newGroupIDs) != Set(lastSnapshotGroupIDs)
        dataSource.apply(snapshot, animatingDifferences: itemsAddedOrRemoved)

        lastSnapshotGroupIDs = newGroupIDs
        lastGroupStates = newStates
    }

    // MARK: - NSCollectionViewDelegateFlowLayout

    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> NSSize {
        guard let item = dataSource.itemIdentifier(for: indexPath) else {
            return NSSize(width: minCardWidth, height: 120)
        }

        let width = cardWidth(for: collectionView.bounds.width)

        switch item {
        case .group(let groupID):
            let faceCount = viewModel.group(byID: groupID)?.faceIDs.count ?? 0
            let isExpanded = expandedGroupIDs.contains(groupID)
            let height = FaceGroupCardView.computeHeight(
                faceCount: faceCount,
                cardWidth: width,
                isExpanded: isExpanded,
                maxVisibleFaces: maxVisibleFaces
            )
            return NSSize(width: width, height: height)

        case .newGroupTarget:
            return NSSize(width: width, height: 120)
        }
    }

    // MARK: - Layout Invalidation on Resize

    override func viewDidLayout() {
        super.viewDidLayout()
        collectionView.collectionViewLayout?.invalidateLayout()
    }

    // MARK: - Expand/Collapse

    func toggleExpand(groupID: UUID) {
        if expandedGroupIDs.contains(groupID) {
            expandedGroupIDs.remove(groupID)
        } else {
            expandedGroupIDs.insert(groupID)
        }

        // Reload the item and invalidate layout (height changed)
        var snapshot = dataSource.snapshot()
        snapshot.reloadItems([.group(groupID)])
        dataSource.apply(snapshot, animatingDifferences: false)
        collectionView.collectionViewLayout?.invalidateLayout()
    }

    // MARK: - Keyboard Navigation

    func navigateFace(direction: NavigationDirection, shift: Bool) {
        let allFaces = allVisibleFaceIDs()
        guard !allFaces.isEmpty else { return }

        let fallbackFaceID = allFaces[0]
        let currentFocusID = selectionState.focusedFaceID ?? selectionState.selectedFaceIDs.first ?? fallbackFaceID
        guard let currentIndex = allFaces.firstIndex(of: currentFocusID) else {
            selectionState.selectFace(fallbackFaceID)
            collectionView.refreshVisibleSelections()
            return
        }

        let columnsPerGroup = 3 // Approximate based on 90px face in ~300px cards
        let newIndex: Int
        switch direction {
        case .left:  newIndex = max(0, currentIndex - 1)
        case .right: newIndex = min(allFaces.count - 1, currentIndex + 1)
        case .up:    newIndex = max(0, currentIndex - columnsPerGroup)
        case .down:  newIndex = min(allFaces.count - 1, currentIndex + columnsPerGroup)
        }

        let newFaceID = allFaces[newIndex]

        if shift {
            selectionState.extendSelection(to: newFaceID, allFaces: allFaces)
        } else {
            selectionState.selectFace(newFaceID)
        }

        // Update thumbnail replacement selection
        if let faceGroupID = viewModel.face(byID: newFaceID)?.groupID {
            viewModel.selectGroupForThumbnailReplacement(faceGroupID, faceID: newFaceID)
        }

        collectionView.refreshVisibleSelections()
        scrollToFace(newFaceID)
    }

    func openFullscreenForSelectedFace() {
        guard selectionState.selectedFaceIDs.count == 1,
              let faceID = selectionState.selectedFaceIDs.first,
              let face = viewModel.face(byID: faceID) else { return }
        callbacks.onOpenFullScreen?(face.imageURL, faceID)
    }

    func deleteSelectedFaces() {
        guard !selectionState.selectedFaceIDs.isEmpty else { return }
        viewModel.deleteFaces(selectionState.selectedFaceIDs)
        selectionState.selectedFaceIDs.removeAll()
        selectionState.focusedFaceID = nil
    }

    func createGroupFromSelection() {
        guard !selectionState.selectedFaceIDs.isEmpty else { return }
        viewModel.createNewGroup(withFaces: selectionState.selectedFaceIDs)
        selectionState.selectedFaceIDs.removeAll()
        selectionState.focusedFaceID = nil
    }

    // MARK: - Helpers

    private func allVisibleFaceIDs() -> [UUID] {
        var faceIDs: [UUID] = []
        for group in viewModel.sortedGroups {
            let faces = viewModel.faces(in: group)
            let isExpanded = expandedGroupIDs.contains(group.id)
            let visibleFaces = isExpanded ? faces : Array(faces.prefix(maxVisibleFaces))
            faceIDs.append(contentsOf: visibleFaces.map(\.id))
        }
        return faceIDs
    }

    private func scrollToFace(_ faceID: UUID) {
        // Find which group contains this face and scroll to that item
        guard let face = viewModel.face(byID: faceID),
              let groupID = face.groupID,
              let index = lastSnapshotGroupIDs.firstIndex(of: groupID) else { return }
        let indexPath = IndexPath(item: index, section: 0)
        collectionView.scrollToItems(at: [indexPath], scrollPosition: .centeredVertically)
    }
}
