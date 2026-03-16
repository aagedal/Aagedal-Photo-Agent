import AppKit

/// Custom NSCollectionView subclass handling mouse, keyboard, drag, and context menu.
final class ThumbnailCollectionView: NSCollectionView {

    weak var viewModel: BrowserViewModel?

    private var isDragging = false
    private var mouseDownLocation: NSPoint?
    private var dropIndicatorLayer: CALayer?
    private var pendingReorderTarget: URL?
    private var pendingInsertBefore = true
    private static var extensionIconCache: [String: NSImage] = [:]

    // MARK: - Immediate Selection Update

    /// Synchronously updates selection visuals on all visible cells and scrolls to the anchor.
    /// Accepts explicit parameters so CALayer updates can happen before @Observable state changes.
    func refreshVisibleSelections(selectedIDs: Set<URL>, activeURL: URL?) {
        guard let viewModel else { return }

        for item in visibleItems() {
            guard let thumbnailItem = item as? ThumbnailCollectionViewItem,
                  let indexPath = indexPath(for: item),
                  indexPath.item < viewModel.visibleImages.count else { continue }
            let url = viewModel.visibleImages[indexPath.item].url
            let isSelected = selectedIDs.contains(url)
            let isActive = isSelected && url == activeURL
            thumbnailItem.thumbnailView.updateSelection(isSelected: isSelected, isActive: isActive)
        }

        // Scroll to active item if needed
        if let activeURL, let index = viewModel.urlToVisibleIndex[activeURL] {
            let indexPath = IndexPath(item: index, section: 0)
            scrollToItemIfNeeded(at: indexPath)
        }
    }

    /// Convenience: refresh from current viewModel state (used by observeSelection and context menu).
    func refreshVisibleSelections() {
        guard let viewModel else { return }
        refreshVisibleSelections(selectedIDs: viewModel.selectedImageIDs, activeURL: viewModel.lastClickedImageURL)
    }

    /// Fast-path for single-selection keyboard navigation: updates only the 2 affected cells
    /// (deselect old, select new) instead of iterating all visible cells.
    private func fastUpdateSelection(from oldURL: URL?, to newURL: URL) {
        if let oldURL, oldURL != newURL,
           let oldIndex = viewModel?.urlToVisibleIndex[oldURL] {
            let ip = IndexPath(item: oldIndex, section: 0)
            if let old = item(at: ip) as? ThumbnailCollectionViewItem {
                old.thumbnailView.updateSelection(isSelected: false, isActive: false)
            }
        }
        if let newIndex = viewModel?.urlToVisibleIndex[newURL] {
            let ip = IndexPath(item: newIndex, section: 0)
            if let new = item(at: ip) as? ThumbnailCollectionViewItem {
                new.thumbnailView.updateSelection(isSelected: true, isActive: true)
            }
            scrollToItemIfNeeded(at: ip)
        }
    }

    /// Scrolls to the item only if it is more than half outside the visible area.
    /// When scrolling is needed, scrolls the minimum amount to make the item fully visible.
    func scrollToItemIfNeeded(at indexPath: IndexPath) {
        guard let layoutAttributes = collectionViewLayout?.layoutAttributesForItem(at: indexPath),
              let scrollView = enclosingScrollView else { return }

        let itemFrame = layoutAttributes.frame
        let visibleRect = scrollView.documentVisibleRect
        let intersection = itemFrame.intersection(visibleRect)

        // If more than half the item is visible, don't scroll
        if !intersection.isNull && intersection.height >= itemFrame.height / 2 {
            return
        }

        // Scroll the minimum amount to make the item fully visible
        scrollToVisible(itemFrame)
    }

    // MARK: - First Responder

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        super.resignFirstResponder()
    }

    // MARK: - Column Count

    var columnCount: Int {
        guard let layout = collectionViewLayout as? NSCollectionViewFlowLayout else { return 1 }
        let availableWidth = bounds.width - layout.sectionInset.left - layout.sectionInset.right
        let itemWidth = layout.itemSize.width
        let spacing = layout.minimumInteritemSpacing
        guard itemWidth > 0 else { return 1 }
        let count = Int((availableWidth + spacing) / (itemWidth + spacing))
        return max(count, 1)
    }

    // MARK: - Mouse Handling

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        mouseDownLocation = convert(event.locationInWindow, from: nil)
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isDragging, let start = mouseDownLocation else { return }

        let current = convert(event.locationInWindow, from: nil)
        let deltaX = abs(current.x - start.x)
        let deltaY = abs(current.y - start.y)
        if deltaX < 3 && deltaY < 3 { return }

        guard let viewModel else { return }

        // Determine which URLs to drag
        let clickPoint = start
        var urls: [URL] = []

        if let indexPath = indexPathForItem(at: clickPoint),
           indexPath.item < viewModel.visibleImages.count {
            let clickedURL = viewModel.visibleImages[indexPath.item].url
            let selection = viewModel.visibleImages
                .filter { viewModel.selectedImageIDs.contains($0.url) }
                .map(\.url)

            if selection.contains(clickedURL) && selection.count > 1 {
                urls = selection
            } else {
                urls = [clickedURL]
            }
        }

        guard !urls.isEmpty else { return }
        isDragging = true

        // Switch to manual sort on first drag
        if viewModel.sortOrder != .manual {
            viewModel.initializeManualOrder(from: viewModel.sortedImages)
            viewModel.sortOrder = .manual
        }
        viewModel.draggedImageURLs = Set(urls)

        let items = makeDraggingItems(for: urls)
        beginDraggingSession(with: items, event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        let location = mouseDownLocation
        mouseDownLocation = nil

        guard !isDragging, let viewModel, let location else {
            isDragging = false
            return
        }
        isDragging = false

        // Dismiss any active text field
        if let responder = window?.firstResponder,
           responder is NSText || responder is NSTextView {
            window?.makeFirstResponder(nil)
        }

        guard let indexPath = indexPathForItem(at: location),
              indexPath.item < viewModel.visibleImages.count else {
            // Clicked empty area — deselect
            viewModel.selectedImageIDs = []
            viewModel.lastClickedImageURL = nil
            refreshVisibleSelections()
            return
        }

        let url = viewModel.visibleImages[indexPath.item].url
        let modifiers = event.modifierFlags

        if event.clickCount == 2 {
            // Double-click: apply immediately (FullScreenImageView needs selection on same frame)
            viewModel.selectedImageIDs = [url]
            viewModel.lastClickedImageURL = url
            viewModel.isFullScreen = true
            refreshVisibleSelections()
        } else {
            // Single click: compute new selection, update visuals immediately, defer state
            let newIDs: Set<URL>
            let newActive: URL?

            if modifiers.contains(.command) {
                var updated = viewModel.selectedImageIDs
                if updated.contains(url) {
                    updated.remove(url)
                } else {
                    updated.insert(url)
                }
                newIDs = updated
                newActive = url
            } else if modifiers.contains(.shift) {
                let anchor = viewModel.lastClickedImageURL ?? viewModel.selectedImageIDs.first
                if let anchor,
                   let anchorIndex = viewModel.urlToVisibleIndex[anchor],
                   let currentIndex = viewModel.urlToVisibleIndex[url] {
                    let range = min(anchorIndex, currentIndex)...max(anchorIndex, currentIndex)
                    var updated = viewModel.selectedImageIDs
                    updated.reserveCapacity(updated.count + range.count)
                    updated.formUnion(viewModel.visibleImages[range].lazy.map(\.url))
                    newIDs = updated
                    newActive = url
                } else {
                    newIDs = [url]
                    newActive = url
                }
            } else {
                newIDs = [url]
                newActive = url
            }

            refreshVisibleSelections(selectedIDs: newIDs, activeURL: newActive)
            viewModel.applySelection(ids: newIDs, active: newActive)
        }
    }

    // MARK: - Keyboard Handling

    override func keyDown(with event: NSEvent) {
        guard let viewModel else {
            super.keyDown(with: event)
            return
        }

        let shift = event.modifierFlags.contains(.shift)
        let cmd = event.modifierFlags.contains(.command)

        switch Int(event.keyCode) {
        case 123: // Left arrow
            let oldActive = viewModel.lastClickedImageURL
            guard let sel = viewModel.computePreviousSelection(extending: shift) else { break }
            if !shift, let newActive = sel.active {
                fastUpdateSelection(from: oldActive, to: newActive)
            } else {
                refreshVisibleSelections(selectedIDs: sel.ids, activeURL: sel.active)
            }
            viewModel.applySelection(ids: sel.ids, active: sel.active)
        case 124: // Right arrow
            let oldActive = viewModel.lastClickedImageURL
            guard let sel = viewModel.computeNextSelection(extending: shift) else { break }
            if !shift, let newActive = sel.active {
                fastUpdateSelection(from: oldActive, to: newActive)
            } else {
                refreshVisibleSelections(selectedIDs: sel.ids, activeURL: sel.active)
            }
            viewModel.applySelection(ids: sel.ids, active: sel.active)
        case 125: // Down arrow
            let oldActive = viewModel.lastClickedImageURL
            guard let sel = viewModel.computeDownSelection(columns: columnCount, extending: shift) else { break }
            if !shift, let newActive = sel.active {
                fastUpdateSelection(from: oldActive, to: newActive)
            } else {
                refreshVisibleSelections(selectedIDs: sel.ids, activeURL: sel.active)
            }
            viewModel.applySelection(ids: sel.ids, active: sel.active)
        case 126: // Up arrow
            let oldActive = viewModel.lastClickedImageURL
            guard let sel = viewModel.computeUpSelection(columns: columnCount, extending: shift) else { break }
            if !shift, let newActive = sel.active {
                fastUpdateSelection(from: oldActive, to: newActive)
            } else {
                refreshVisibleSelections(selectedIDs: sel.ids, activeURL: sel.active)
            }
            viewModel.applySelection(ids: sel.ids, active: sel.active)
        case 49: // Space
            // Only handle when no text field is focused
            guard viewModel.firstSelectedImage != nil else {
                super.keyDown(with: event)
                return
            }
            if let responder = window?.firstResponder,
               responder is NSText || responder is NSTextView {
                super.keyDown(with: event)
                return
            }
            viewModel.isFullScreen = true
        case 0: // A key
            if cmd {
                guard let sel = viewModel.computeSelectAll() else { break }
                refreshVisibleSelections(selectedIDs: sel.ids, activeURL: sel.active)
                viewModel.applySelection(ids: sel.ids, active: sel.active)
            } else {
                super.keyDown(with: event)
            }
        case 3: // F key
            if cmd, viewModel.firstSelectedImage != nil {
                viewModel.isFullScreen.toggle()
            } else {
                super.keyDown(with: event)
            }
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Context Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let viewModel else { return nil }

        let location = convert(event.locationInWindow, from: nil)

        // If right-clicked item not in selection, select it first
        if let indexPath = indexPathForItem(at: location),
           indexPath.item < viewModel.visibleImages.count {
            let url = viewModel.visibleImages[indexPath.item].url
            if !viewModel.selectedImageIDs.contains(url) {
                viewModel.selectedImageIDs = [url]
                viewModel.lastClickedImageURL = url
                refreshVisibleSelections()
            }
        }

        let menu = NSMenu()

        // Reveal in Finder
        let revealItem = NSMenuItem(title: "Reveal in Finder", action: #selector(contextRevealInFinder(_:)), keyEquivalent: "")
        revealItem.target = self
        menu.addItem(revealItem)

        // Open in External Editor
        if let editorPath = UserDefaults.standard.string(forKey: UserDefaultsKeys.defaultExternalEditor),
           !editorPath.isEmpty {
            let editorItem = NSMenuItem(title: "Open in External Editor", action: #selector(contextOpenInExternalEditor(_:)), keyEquivalent: "")
            editorItem.target = self
            menu.addItem(editorItem)
        }

        // Copy File Path(s)
        let copyItem = NSMenuItem(title: "Copy File Path(s)", action: #selector(contextCopyFilePaths(_:)), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)

        menu.addItem(NSMenuItem.separator())

        // Add to Subfolder
        if viewModel.currentFolderURL != nil {
            let subfolderItem = NSMenuItem(title: "Add to Subfolder...", action: #selector(contextAddToSubfolder(_:)), keyEquivalent: "")
            subfolderItem.target = self
            menu.addItem(subfolderItem)
            menu.addItem(NSMenuItem.separator())
        }

        // Rating submenu
        let ratingMenu = NSMenu()
        for rating in StarRating.allCases {
            let title = rating == .none ? "No Rating" : rating.displayString
            let ratingItem = NSMenuItem(title: title, action: #selector(contextSetRating(_:)), keyEquivalent: "")
            ratingItem.target = self
            ratingItem.representedObject = rating
            ratingMenu.addItem(ratingItem)
        }
        let ratingSubmenu = NSMenuItem(title: "Rating", action: nil, keyEquivalent: "")
        ratingSubmenu.submenu = ratingMenu
        menu.addItem(ratingSubmenu)

        // Label submenu
        let labelMenu = NSMenu()
        for label in ColorLabel.allCases {
            let labelItem = NSMenuItem(title: label.displayName, action: #selector(contextSetLabel(_:)), keyEquivalent: "")
            labelItem.target = self
            labelItem.representedObject = label
            labelMenu.addItem(labelItem)
        }
        let labelSubmenu = NSMenuItem(title: "Label", action: nil, keyEquivalent: "")
        labelSubmenu.submenu = labelMenu
        menu.addItem(labelSubmenu)

        menu.addItem(NSMenuItem.separator())

        // Save As
        let saveJPEGItem = NSMenuItem(title: "Save as JPEG", action: #selector(contextSaveAsJPEG(_:)), keyEquivalent: "")
        saveJPEGItem.target = self
        menu.addItem(saveJPEGItem)

        let savePNGItem = NSMenuItem(title: "Save as PNG", action: #selector(contextSaveAsPNG(_:)), keyEquivalent: "")
        savePNGItem.target = self
        menu.addItem(savePNGItem)

        menu.addItem(NSMenuItem.separator())

        // Rename / Duplicate
        let renameItem = NSMenuItem(title: "Rename...", action: #selector(contextRename(_:)), keyEquivalent: "")
        renameItem.target = self
        menu.addItem(renameItem)

        let duplicateItem = NSMenuItem(title: "Duplicate", action: #selector(contextDuplicate(_:)), keyEquivalent: "")
        duplicateItem.target = self
        menu.addItem(duplicateItem)

        menu.addItem(NSMenuItem.separator())

        // Reset / Remove
        let resetItem = NSMenuItem(title: "Reset All Edits", action: #selector(contextResetAllEdits(_:)), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)

        let removeIPTCItem = NSMenuItem(title: "Remove All IPTC Metadata", action: #selector(contextRemoveAllIPTC(_:)), keyEquivalent: "")
        removeIPTCItem.target = self
        menu.addItem(removeIPTCItem)

        menu.addItem(NSMenuItem.separator())

        // Delete
        let deleteItem = NSMenuItem(title: "Move to Trash", action: #selector(contextDelete(_:)), keyEquivalent: "")
        deleteItem.target = self
        menu.addItem(deleteItem)

        return menu
    }

    // MARK: - Context Menu Actions

    @objc private func contextRevealInFinder(_ sender: Any?) {
        guard let viewModel else { return }
        let urls = viewModel.selectedImages.map(\.url)
        if urls.count > 1 {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        } else if let url = urls.first {
            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
        }
    }

    @objc private func contextOpenInExternalEditor(_ sender: Any?) {
        guard let viewModel,
              let editorPath = UserDefaults.standard.string(forKey: UserDefaultsKeys.defaultExternalEditor),
              !editorPath.isEmpty else { return }
        let urls = viewModel.selectedImages.map(\.url)
        NSWorkspace.shared.open(urls, withApplicationAt: URL(fileURLWithPath: editorPath), configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func contextCopyFilePaths(_ sender: Any?) {
        guard let viewModel else { return }
        let paths = viewModel.selectedImages.map(\.url.path).joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(paths, forType: .string)
    }

    @objc private func contextAddToSubfolder(_ sender: Any?) {
        viewModel?.promptAddSelectedImagesToSubfolder()
    }

    @objc private func contextSetRating(_ sender: NSMenuItem) {
        guard let rating = sender.representedObject as? StarRating else { return }
        NotificationCenter.default.post(name: .setRating, object: rating)
    }

    @objc private func contextSetLabel(_ sender: NSMenuItem) {
        guard let label = sender.representedObject as? ColorLabel else { return }
        NotificationCenter.default.post(name: .setLabel, object: label)
    }

    @objc private func contextSaveAsJPEG(_ sender: Any?) {
        NotificationCenter.default.post(name: .saveAsJPEG, object: nil)
    }

    @objc private func contextSaveAsPNG(_ sender: Any?) {
        NotificationCenter.default.post(name: .saveAsPNG, object: nil)
    }

    @objc private func contextRename(_ sender: Any?) {
        NotificationCenter.default.post(name: .renameSelected, object: nil)
    }

    @objc private func contextDuplicate(_ sender: Any?) {
        NotificationCenter.default.post(name: .duplicateSelected, object: nil)
    }

    @objc private func contextResetAllEdits(_ sender: Any?) {
        NotificationCenter.default.post(name: .resetAllEdits, object: nil)
    }

    @objc private func contextRemoveAllIPTC(_ sender: Any?) {
        NotificationCenter.default.post(name: .removeAllIPTC, object: nil)
    }

    @objc private func contextDelete(_ sender: Any?) {
        viewModel?.confirmDeleteSelectedImages()
    }

    // MARK: - NSDraggingSource

    override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : .move
    }

    override func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        guard let window = self.window else { return }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let localPoint = convert(windowPoint, from: nil)

        guard let viewModel,
              let indexPath = indexPathForItem(at: localPoint),
              indexPath.item < viewModel.visibleImages.count else {
            hideDropIndicator()
            return
        }

        let targetURL = viewModel.visibleImages[indexPath.item].url
        guard !viewModel.draggedImageURLs.contains(targetURL) else {
            hideDropIndicator()
            return
        }

        guard let attrs = collectionViewLayout?.layoutAttributesForItem(at: indexPath) else { return }
        let itemFrame = attrs.frame
        let insertBefore = localPoint.x < itemFrame.midX

        // Skip update if target hasn't changed
        if targetURL == pendingReorderTarget && insertBefore == pendingInsertBefore { return }

        pendingReorderTarget = targetURL
        pendingInsertBefore = insertBefore
        showDropIndicator(itemFrame: itemFrame, insertBefore: insertBefore)
    }

    override func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        hideDropIndicator()

        // Only reorder if the drop ended within the collection view
        if let window = self.window, let target = pendingReorderTarget {
            let windowPoint = window.convertPoint(fromScreen: screenPoint)
            let localPoint = convert(windowPoint, from: nil)
            if visibleRect.contains(localPoint) {
                reorderDraggedItems(to: target, insertBefore: pendingInsertBefore)
            }
        }

        isDragging = false
        pendingReorderTarget = nil
        viewModel?.draggedImageURLs = []
    }

    private func reorderDraggedItems(to targetURL: URL, insertBefore: Bool) {
        guard let viewModel else { return }
        let draggedURLs = viewModel.draggedImageURLs
        guard !draggedURLs.isEmpty, !draggedURLs.contains(targetURL) else { return }

        // Collect dragged items in their current order
        let draggedItems = viewModel.manualOrder.filter { draggedURLs.contains($0) }
        guard !draggedItems.isEmpty else { return }

        // Remove dragged items
        viewModel.manualOrder.removeAll { draggedURLs.contains($0) }

        // Insert at the indicated position
        guard let targetIndex = viewModel.manualOrder.firstIndex(of: targetURL) else { return }
        let insertionIndex = insertBefore ? targetIndex : targetIndex + 1
        viewModel.manualOrder.insert(contentsOf: draggedItems, at: insertionIndex)
    }

    // MARK: - Drop Indicator

    private func ensureDropIndicator() -> CALayer {
        if let existing = dropIndicatorLayer { return existing }
        let indicator = CALayer()
        indicator.backgroundColor = NSColor.controlAccentColor.cgColor
        indicator.cornerRadius = 1.5
        indicator.zPosition = 1000
        indicator.isHidden = true
        dropIndicatorLayer = indicator
        wantsLayer = true
        layer?.addSublayer(indicator)
        return indicator
    }

    private func showDropIndicator(itemFrame: CGRect, insertBefore: Bool) {
        let indicator = ensureDropIndicator()

        let spacing = (collectionViewLayout as? NSCollectionViewFlowLayout)?.minimumInteritemSpacing ?? 8
        let indicatorWidth: CGFloat = 3
        let indicatorX: CGFloat

        if insertBefore {
            indicatorX = itemFrame.minX - spacing / 2 - indicatorWidth / 2
        } else {
            indicatorX = itemFrame.maxX + spacing / 2 - indicatorWidth / 2
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        indicator.frame = CGRect(x: indicatorX, y: itemFrame.minY, width: indicatorWidth, height: itemFrame.height)
        indicator.isHidden = false
        CATransaction.commit()
    }

    private func hideDropIndicator() {
        guard let indicator = dropIndicatorLayer, !indicator.isHidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        indicator.isHidden = true
        CATransaction.commit()
    }

    private func makeDraggingItems(for urls: [URL]) -> [NSDraggingItem] {
        var items: [NSDraggingItem] = []
        let iconSize = NSSize(width: 64, height: 64)
        let baseFrame = NSRect(origin: .zero, size: iconSize)
        let maxVisualItems = 5

        for (index, url) in urls.enumerated() {
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            if index < maxVisualItems {
                let icon = dragIcon(for: url)
                icon.size = iconSize
                let offset = CGFloat(index) * 6
                let frame = baseFrame.offsetBy(dx: offset, dy: -offset)
                item.setDraggingFrame(frame, contents: icon)
            } else {
                item.setDraggingFrame(baseFrame, contents: nil)
            }
            items.append(item)
        }
        return items
    }

    private func dragIcon(for url: URL) -> NSImage {
        if let thumbnail = viewModel?.thumbnailService.thumbnail(for: url) {
            return thumbnail
        }
        let ext = url.pathExtension.lowercased()
        if let cached = ThumbnailCollectionView.extensionIconCache[ext] {
            return cached
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        ThumbnailCollectionView.extensionIconCache[ext] = icon
        return icon
    }
}
