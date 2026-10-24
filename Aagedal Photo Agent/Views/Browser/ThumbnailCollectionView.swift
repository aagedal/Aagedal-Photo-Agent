import AppKit

/// Custom NSCollectionView subclass handling mouse, keyboard, drag, and context menu.
final class ThumbnailCollectionView: NSCollectionView {

    weak var viewModel: BrowserViewModel?
    weak var commandRouter: AppCommandRouter?

    /// Fired on mouseDown, right-click, keyboard focus and key presses so the split-view
    /// container can mark this pane active. App commands (ratings, labels, context-menu
    /// actions) and the full-screen viewer act on the active pane.
    var onFocus: (() -> Void)?
    /// Whether this grid's pane is the active split pane (kept current by the controller).
    var isActivePane = true
    var onExtractVideoStills: ((URL) -> Void)?
    var onImproveDescriptions: (() -> Void)?

    private var isDragging = false
    /// Set at drag start when the dragged photos may not leave the app as original files
    /// (Anonymizer redactions, settings not loaded yet, or the unredacted JPEG of a redacted
    /// RAW). Drops onto other apps are refused; in-app moves stay allowed.
    private var outsideDragBlockMessage: String?
    private var outsideDragWasRefused = false
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

        Self.refreshSelection(in: Array(visibleItems()), selectedIDs: selectedIDs, activeURL: activeURL)

        // Scroll to active item if needed
        if let activeURL, let index = viewModel.urlToVisibleIndex[activeURL] {
            let indexPath = IndexPath(item: index, section: 0)
            scrollToItemIfNeeded(at: indexPath)
        }
    }

    /// Selection belongs to the configured source, not its possibly stale index in
    /// an animated diffable snapshot. Also covers outgoing and newly inserted cells.
    static func refreshSelection(
        in items: [NSCollectionViewItem],
        selectedIDs: Set<URL>,
        activeURL: URL?
    ) {
        for item in items {
            guard let thumbnailItem = item as? ThumbnailCollectionViewItem,
                  let url = thumbnailItem.currentURL else { continue }
            let isSelected = selectedIDs.contains(url)
            thumbnailItem.thumbnailView.updateSelection(
                isSelected: isSelected,
                isActive: isSelected && url == activeURL
            )
        }
    }

    /// Convenience: refresh from current viewModel state (used by observeSelection and context menu).
    func refreshVisibleSelections() {
        guard let viewModel else { return }
        refreshVisibleSelections(selectedIDs: viewModel.selectedImageIDs, activeURL: viewModel.lastClickedImageURL)
    }

    /// Update the visible cells by source identity even while a snapshot insertion
    /// is in flight. Looking up the old/new model indexes can select a different cell.
    private func updateSingleSelection(to newURL: URL) {
        refreshVisibleSelections(selectedIDs: [newURL], activeURL: newURL)
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
        let accepted = super.becomeFirstResponder()
        // Keyboard focus reaching an inactive pane (Tab, accessibility) activates it, so the
        // shortcuts typed next act on the photos this grid shows.
        if accepted, !isActivePane { onFocus?() }
        return accepted
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
        onFocus?()
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

        // Sort switches to Manual only when the drop actually reorders inside the grid
        // (see reorderDraggedItems); drags to Finder, Mail, or a sidebar folder keep it.
        viewModel.draggedImageURLs = Set(urls)
        outsideDragBlockMessage = RedactionPrivacyGuard.outsideDragDecision(
            for: urls.compactMap { viewModel.image(at: $0) },
            candidates: viewModel.images
        ).message
        outsideDragWasRefused = false
        if outsideDragBlockMessage == RedactionPrivacyGuard.dragPendingMessage {
            // Settings not read yet: this drag is refused, but read them now so the next works.
            viewModel.ensureDevelopSettingsLoaded(for: urls, limit: 200)
        }

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
                let anchor = viewModel.shiftSelectionAnchorURL
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

            let extending = modifiers.contains(.shift) && !modifiers.contains(.command)
            refreshVisibleSelections(selectedIDs: newIDs, activeURL: newActive)
            DispatchQueue.main.async { [weak viewModel] in
                viewModel?.applySelection(ids: newIDs, active: newActive, extending: extending)
            }
        }
    }

    // MARK: - Keyboard Handling

    override func keyDown(with event: NSEvent) {
        guard let viewModel else {
            super.keyDown(with: event)
            return
        }
        // Culling keys route through the app command router to the active pane, and Space
        // opens the full-screen viewer only for the active pane: the pane with keyboard
        // focus must be that pane.
        if !isActivePane { onFocus?() }

        let shift = event.modifierFlags.contains(.shift)
        let cmd = event.modifierFlags.contains(.command)

        let profile = KeyboardShortcutProfileRegistry.shared.selectedProfile
        let inputState = keyboardTextInputState(in: window)
        if let chord = KeyboardShortcutChord(event: event), let command = profile.command(for: chord) {
            if command.isCulling {
                if viewModel.firstSelectedImage != nil,
                   !inputState.textEditorOwnsInput, !inputState.imeHasMarkedText {
                    if !event.isARepeat, let action = command.action { applyCullingShortcut(action) }
                    return
                }
            } else {
                // Native menu equivalents own all modified app commands, including
                // template slots. Never revive an unassigned Control+digit shortcut.
                if !event.isARepeat { super.keyDown(with: event) }
                return
            }
        }

        switch Int(event.keyCode) {
        case 123: // Left arrow
            guard let sel = viewModel.computePreviousSelection(extending: shift) else { break }
            if !shift, let newActive = sel.active {
                updateSingleSelection(to: newActive)
            } else {
                refreshVisibleSelections(selectedIDs: sel.ids, activeURL: sel.active)
            }
            viewModel.applySelection(ids: sel.ids, active: sel.active, extending: shift)
        case 124: // Right arrow
            guard let sel = viewModel.computeNextSelection(extending: shift) else { break }
            if !shift, let newActive = sel.active {
                updateSingleSelection(to: newActive)
            } else {
                refreshVisibleSelections(selectedIDs: sel.ids, activeURL: sel.active)
            }
            viewModel.applySelection(ids: sel.ids, active: sel.active, extending: shift)
        case 125: // Down arrow
            guard let sel = viewModel.computeDownSelection(columns: columnCount, extending: shift) else { break }
            if !shift, let newActive = sel.active {
                updateSingleSelection(to: newActive)
            } else {
                refreshVisibleSelections(selectedIDs: sel.ids, activeURL: sel.active)
            }
            viewModel.applySelection(ids: sel.ids, active: sel.active, extending: shift)
        case 126: // Up arrow
            guard let sel = viewModel.computeUpSelection(columns: columnCount, extending: shift) else { break }
            if !shift, let newActive = sel.active {
                updateSingleSelection(to: newActive)
            } else {
                refreshVisibleSelections(selectedIDs: sel.ids, activeURL: sel.active)
            }
            viewModel.applySelection(ids: sel.ids, active: sel.active, extending: shift)
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

    private func applyCullingShortcut(_ action: KeyboardCullingAction) {
        switch action {
        case let .rating(value):
            guard let rating = StarRating(rawValue: value) else { return }
            commandRouter?.send(.setRating(rating))
        case let .colorLabel(index):
            guard let label = ColorLabel.fromShortcutIndex(index) else { return }
            commandRouter?.send(.setLabel(label))
        }
    }

    // MARK: - Context Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let viewModel else { return nil }
        // Menu actions route through the command router to the active pane; activate this
        // pane first so they never hit the other pane's selection.
        onFocus?()

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

        // Items carry explicit enablement; AppKit auto-validation would ignore isEnabled.
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Reveal in Finder
        let revealItem = NSMenuItem(title: "Reveal in Finder", action: #selector(contextRevealInFinder(_:)), keyEquivalent: "")
        revealItem.target = self
        menu.addItem(revealItem)

        if let indexPath = indexPathForItem(at: location), indexPath.item < viewModel.visibleImages.count {
            let file = viewModel.visibleImages[indexPath.item]
            if BrowserFileVisibility.isVideo(file.url) {
                let extractItem = NSMenuItem(title: "Extract still(s) from video…", action: #selector(contextExtractVideoStills(_:)), keyEquivalent: "")
                extractItem.target = self
                extractItem.representedObject = file.url
                extractItem.isEnabled = onExtractVideoStills != nil && !file.isICloudDownloadPending
                menu.addItem(extractItem)
            }
        }

        // Open in External Editor
        if let editorPath = AppDefaults.store.string(forKey: UserDefaultsKeys.defaultExternalEditor),
           !editorPath.isEmpty {
            let editorItem = NSMenuItem(title: "Open in External Editor", action: #selector(contextOpenInExternalEditor(_:)), keyEquivalent: "")
            editorItem.target = self
            menu.addItem(editorItem)
        }

        let transcriptionItem = NSMenuItem(title: "Transcribe Voice Memos…", action: #selector(contextTranscribeVoiceMemos(_:)), keyEquivalent: "")
        transcriptionItem.target = self
        transcriptionItem.isEnabled = (1...AutomationVoiceTranscriptionBatchService.maximumPhotos).contains(viewModel.selectedImages.count)
            && viewModel.selectedImages.allSatisfy(\.isImageFile)
        menu.addItem(transcriptionItem)

        let descriptionItem = NSMenuItem(title: "Improve Descriptions with AI…", action: #selector(contextImproveDescriptions(_:)), keyEquivalent: "")
        descriptionItem.target = self
        descriptionItem.isEnabled = onImproveDescriptions != nil
            && !viewModel.selectedImages.isEmpty
            && viewModel.selectedImages.allSatisfy(\.isImageFile)
        menu.addItem(descriptionItem)

        // Copy File Path(s)
        let copyItem = NSMenuItem(title: "Copy File Path(s)", action: #selector(contextCopyFilePaths(_:)), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)

        menu.addItem(NSMenuItem.separator())

        // Add to Subfolder / Move to Folder
        if viewModel.currentFolderURL != nil {
            let subfolderItem = NSMenuItem(title: "Add to Subfolder...", action: #selector(contextAddToSubfolder(_:)), keyEquivalent: "")
            subfolderItem.target = self
            menu.addItem(subfolderItem)

            let moveToFolderItem = NSMenuItem(title: "Move to Folder...", action: #selector(contextMoveToFolder(_:)), keyEquivalent: "")
            moveToFolderItem.target = self
            menu.addItem(moveToFolderItem)

            menu.addItem(NSMenuItem.separator())
        }

        // Rating submenu
        let ratingMenu = NSMenu()
        ratingMenu.autoenablesItems = false
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
        labelMenu.autoenablesItems = false
        for label in ColorLabel.allCases {
            let labelItem = NSMenuItem(title: label.displayName, action: #selector(contextSetLabel(_:)), keyEquivalent: "")
            labelItem.target = self
            labelItem.representedObject = label
            labelMenu.addItem(labelItem)
        }
        let labelSubmenu = NSMenuItem(title: "Label", action: nil, keyEquivalent: "")
        labelSubmenu.submenu = labelMenu
        menu.addItem(labelSubmenu)

        if viewModel.hasPendingOrientationInSelection {
            let writeRotation = NSMenuItem(title: "Write Pending Rotation", action: #selector(contextWritePendingRotation(_:)), keyEquivalent: "")
            writeRotation.target = self
            writeRotation.toolTip = "Apply the displayed pending rotation using the current metadata write mode."
            menu.addItem(writeRotation)
        }

        menu.addItem(NSMenuItem.separator())

        // Save As
        let saveJPEGItem = NSMenuItem(title: "Save as JPEG", action: #selector(contextSaveAsJPEG(_:)), keyEquivalent: "")
        saveJPEGItem.target = self
        menu.addItem(saveJPEGItem)

        let savePNGItem = NSMenuItem(title: "Save as PNG", action: #selector(contextSaveAsPNG(_:)), keyEquivalent: "")
        savePNGItem.target = self
        menu.addItem(savePNGItem)

        let rawSelectionCount = viewModel.selectedImages.lazy
            .map(\.url)
            .filter(SupportedImageFormats.isRaw(url:))
            .count
        if rawSelectionCount > 0 {
            let archiveMenu = NSMenu()
            archiveMenu.autoenablesItems = false
            let discovery = AdobeDNGDiscoveryStore.shared
            discovery.refreshInBackground()
            // Unknown availability remains actionable; the action awaits a fresh probe.
            let dngConverterInstalled = !discovery.hasChecked || discovery.executableURL != nil

            for format in RAWArchiveFormat.allCases {
                if format == .dngLossless {
                    archiveMenu.addItem(.separator())
                }
                let unavailableDNG = format.requiresAdobeDNGConverter
                    && !dngConverterInstalled
                let title = unavailableDNG
                    ? "\(format.displayName) — Requires Adobe DNG Converter"
                    : format.displayName
                let item = NSMenuItem(
                    title: title,
                    action: #selector(contextArchiveRAW(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = format
                item.isEnabled = !unavailableDNG
                if unavailableDNG {
                    item.toolTip = "Install the free Adobe DNG Converter to enable DNG archiving."
                }
                archiveMenu.addItem(item)
            }

            if !dngConverterInstalled {
                archiveMenu.addItem(.separator())
                let installItem = NSMenuItem(
                    title: "How to Enable DNG Archiving…",
                    action: #selector(contextShowDNGConverterInstructions(_:)),
                    keyEquivalent: ""
                )
                installItem.target = self
                archiveMenu.addItem(installItem)
            }

            let archiveTitle = rawSelectionCount == 1
                ? "Archive RAW as…"
                : "Archive \(rawSelectionCount) RAW Files as…"
            let archiveItem = NSMenuItem(
                title: archiveTitle,
                action: nil,
                keyEquivalent: ""
            )
            archiveItem.submenu = archiveMenu
            menu.addItem(archiveItem)
        }

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

        // Every grid action works on the selection; a right-click on empty space with
        // nothing selected shows the menu disabled rather than offering no-op actions.
        if viewModel.selectedImageIDs.isEmpty {
            for item in menu.items { item.isEnabled = false }
        }

        return menu
    }

    // MARK: - Context Menu Actions

    @objc private func contextExtractVideoStills(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onFocus?()
        onExtractVideoStills?(url)
    }

    @objc private func contextImproveDescriptions(_ sender: NSMenuItem) {
        onFocus?()
        onImproveDescriptions?()
    }

    @objc private func contextTranscribeVoiceMemos(_ sender: NSMenuItem) {
        commandRouter?.send(.transcribeVoiceMemosSelected)
    }


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
              let editorPath = AppDefaults.store.string(forKey: UserDefaultsKeys.defaultExternalEditor),
              !editorPath.isEmpty else { return }
        let images = viewModel.selectedImages
        guard RedactionPrivacyPrompt.confirmExternalEditor(for: images) else { return }
        let urls = images.map(\.url)
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
        // Return from the NSMenu action before starting NSAlert's modal loop so
        // menu tracking can finish and the prompt can acquire focus/accessibility.
        guard let viewModel else { return }
        DispatchQueue.main.async { [weak viewModel] in
            viewModel?.promptAddSelectedImagesToSubfolder()
        }
    }

    @objc private func contextSetRating(_ sender: NSMenuItem) {
        guard let rating = sender.representedObject as? StarRating else { return }
        commandRouter?.send(.setRating(rating))
    }

    @objc private func contextSetLabel(_ sender: NSMenuItem) {
        guard let label = sender.representedObject as? ColorLabel else { return }
        commandRouter?.send(.setLabel(label))
    }

    @objc private func contextWritePendingRotation(_ sender: Any?) {
        viewModel?.applyPendingOrientationToSelection()
    }

    @objc private func contextSaveAsJPEG(_ sender: Any?) {
        commandRouter?.send(.saveAsJPEG)
    }

    @objc private func contextSaveAsPNG(_ sender: Any?) {
        commandRouter?.send(.saveAsPNG)
    }

    @objc private func contextArchiveRAW(_ sender: NSMenuItem) {
        guard let format = sender.representedObject as? RAWArchiveFormat else { return }
        commandRouter?.send(.archiveRAW(format))
    }

    @objc private func contextShowDNGConverterInstructions(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Enable DNG Archiving"
        alert.informativeText = """
        Lossless and lossy DNG archiving requires the free Adobe DNG Converter.

        Download it from Adobe, run the installer, then reopen this menu. Photoshop and a Creative Cloud subscription are not required.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Adobe Download Page")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(AdobeDNGConverterService.downloadURL)
        }
    }

    @objc private func contextRename(_ sender: Any?) {
        commandRouter?.send(.renameSelected)
    }

    @objc private func contextDuplicate(_ sender: Any?) {
        commandRouter?.send(.duplicateSelected)
    }

    @objc private func contextResetAllEdits(_ sender: Any?) {
        commandRouter?.send(.resetAllEdits)
    }

    @objc private func contextRemoveAllIPTC(_ sender: Any?) {
        commandRouter?.send(.removeAllIPTC)
    }

    @objc private func contextMoveToFolder(_ sender: Any?) {
        // NSOpenPanel also starts a modal loop; present it after menu dismissal.
        guard let viewModel else { return }
        DispatchQueue.main.async { [weak viewModel] in
            viewModel?.promptMoveSelectedImagesToFolder()
        }
    }

    @objc private func contextDelete(_ sender: Any?) {
        viewModel?.confirmDeleteSelectedImages()
    }

    // MARK: - NSDraggingSource

    override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        guard context == .outsideApplication else { return .move }
        // Privacy: Finder, Mail, Slack… would receive the original file, which never carries
        // the face blurs (they are app-only Develop settings).
        if outsideDragBlockMessage != nil {
            outsideDragWasRefused = true
            return []
        }
        return .copy
    }

    override func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        guard let window = self.window else { return }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let localPoint = convert(windowPoint, from: nil)

        // No indicator means no reorder target: a drop elsewhere must not reuse the
        // last item the drag passed over.
        guard let viewModel,
              let indexPath = indexPathForItem(at: localPoint),
              indexPath.item < viewModel.visibleImages.count else {
            pendingReorderTarget = nil
            hideDropIndicator()
            return
        }

        let targetURL = viewModel.visibleImages[indexPath.item].url
        guard !viewModel.draggedImageURLs.contains(targetURL) else {
            pendingReorderTarget = nil
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

        // Explain a refused drop on another app (not a drop that merely ended over our own windows).
        if operation.isEmpty, outsideDragWasRefused, let message = outsideDragBlockMessage,
           !NSApp.windows.contains(where: { $0.isVisible && $0.frame.contains(screenPoint) }) {
            viewModel?.fileOperationNotice = FileOperationNotice(
                message: message, systemImage: "eye.slash"
            )
        }
        outsideDragBlockMessage = nil
        outsideDragWasRefused = false

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
        viewModel.reorderManually(
            viewModel.draggedImageURLs,
            to: targetURL,
            insertBefore: insertBefore
        )
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

        // RAW files dragged to Finder or another app keep their XMP sidecar (ratings,
        // captions, Camera Raw edits). Sidecar items carry no visual of their own. In-app
        // folder drops skip them again (`removingCompanionSidecars`): moves bring sidecars along.
        let sidecars = PhotoDragPasteboardURLs.ownedSidecars(
            for: urls,
            hasSidecar: { [weak viewModel] url in viewModel?.image(at: url)?.sidecarModified != nil }
        )
        for sidecar in sidecars {
            let item = NSDraggingItem(pasteboardWriter: sidecar as NSURL)
            item.setDraggingFrame(baseFrame, contents: nil)
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

/// Extra file URLs for dragging photos out of the grid: the stem `.xmp` sidecar of each RAW,
/// so a Finder copy keeps its ratings, captions and Camera Raw edits.
nonisolated enum PhotoDragPasteboardURLs {
    /// Only RAW files take their stem sidecar along: a RAW owns it (PhotoSidecarOwnership) and
    /// has nowhere else to keep ratings, captions or Camera Raw edits. JPEG/HEIC/TIFF carry
    /// embedded metadata, and extra `.xmp` items on every drag break Mail/Slack attachments,
    /// web uploaders and Photoshop. A RAW+JPEG pair therefore adds the shared `.xmp` once.
    /// `hasSidecar` answers from the folder scan, so a drag never stats per photo.
    static func ownedSidecars(
        for photoURLs: [URL],
        hasSidecar: (URL) -> Bool
    ) -> [URL] {
        var seen: Set<String> = []
        var sidecars: [URL] = []
        for photoURL in photoURLs where SupportedImageFormats.isRaw(url: photoURL) {
            let sidecar = photoURL.deletingPathExtension().appendingPathExtension("xmp")
            let key = sidecar.standardizedFileURL.path.lowercased()
            guard !seen.contains(key), hasSidecar(photoURL) else { continue }
            seen.insert(key)
            sidecars.append(sidecar)
        }
        return sidecars
    }

    /// In-app folder drops move photos with their sidecars already; drop a dragged `.xmp`
    /// whose same-stem photo (same folder) is part of the same drop so it is not moved twice.
    static func removingCompanionSidecars(from urls: [URL]) -> [URL] {
        func stemKey(_ url: URL) -> String {
            url.deletingPathExtension().standardizedFileURL.path.lowercased()
        }
        let photoStems = Set(urls.filter { $0.pathExtension.lowercased() != "xmp" }.map(stemKey))
        return urls.filter { url in
            url.pathExtension.lowercased() != "xmp" || !photoStems.contains(stemKey(url))
        }
    }
}
