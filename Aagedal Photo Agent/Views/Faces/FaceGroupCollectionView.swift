import AppKit

/// Custom NSCollectionView for face group cards — handles keyboard, drag source, and drop destination.
final class FaceGroupCollectionView: NSCollectionView {

    weak var controller: FaceGroupCollectionController?

    private var draggedFaceIDs: Set<UUID> = []
    private var draggedGroupID: UUID?

    // MARK: - First Responder

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        super.resignFirstResponder()
    }

    // MARK: - Immediate Selection Refresh

    func refreshVisibleSelections() {
        guard let controller else { return }
        let selectedIDs = controller.selectionState.selectedFaceIDs
        let focusedID = controller.selectionState.focusedFaceID
        let draggedIDs = controller.selectionState.draggedFaceIDs

        for item in visibleItems() {
            if let cardItem = item as? FaceGroupCardItem {
                cardItem.cardView.updateFaceVisuals(
                    selectedIDs: selectedIDs,
                    focusedID: focusedID,
                    draggedIDs: draggedIDs
                )
            }
        }
    }

    // MARK: - Keyboard Handling

    override func keyDown(with event: NSEvent) {
        // Skip if text field is focused
        if let responder = window?.firstResponder, responder is NSText || responder is NSTextView {
            super.keyDown(with: event)
            return
        }

        guard let controller else {
            super.keyDown(with: event)
            return
        }

        let shift = event.modifierFlags.contains(.shift)
        let cmd = event.modifierFlags.contains(.command)

        switch Int(event.keyCode) {
        case 123: // Left
            controller.navigateFace(direction: .left, shift: shift)
        case 124: // Right
            controller.navigateFace(direction: .right, shift: shift)
        case 125: // Down
            controller.navigateFace(direction: .down, shift: shift)
        case 126: // Up
            controller.navigateFace(direction: .up, shift: shift)
        case 49: // Space
            controller.openFullscreenForSelectedFace()
        case 51, 117: // Delete / Forward Delete
            controller.deleteSelectedFaces()
        case 5: // G key
            if cmd {
                controller.createGroupFromSelection()
            } else {
                super.keyDown(with: event)
            }
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Face Drag

    func beginFaceDrag(faceIDs: Set<UUID>, event: NSEvent, sourceView: NSView, viewModel: FaceRecognitionViewModel) {
        draggedFaceIDs = faceIDs
        draggedGroupID = nil

        let payload = faceIDs.map(\.uuidString).joined(separator: ",")
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(payload, forType: .string)

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)

        // Use face thumbnail as drag image if available
        let iconSize = NSSize(width: 64, height: 64)
        if let firstID = faceIDs.first,
           let thumb = viewModel.thumbnailImage(for: firstID) {
            thumb.size = iconSize
            draggingItem.setDraggingFrame(NSRect(origin: .zero, size: iconSize), contents: thumb)
        } else {
            let placeholder = NSImage(systemSymbolName: "person.fill", accessibilityDescription: nil) ?? NSImage()
            placeholder.size = iconSize
            draggingItem.setDraggingFrame(NSRect(origin: .zero, size: iconSize), contents: placeholder)
        }

        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    // MARK: - Group Drag

    func beginGroupDrag(groupID: UUID, event: NSEvent, sourceView: NSView) {
        draggedFaceIDs = []
        draggedGroupID = groupID

        let payload = "group:\(groupID.uuidString)"
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(payload, forType: .string)

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let iconSize = NSSize(width: 64, height: 64)
        let icon = NSImage(systemSymbolName: "person.3.fill", accessibilityDescription: nil) ?? NSImage()
        icon.size = iconSize
        draggingItem.setDraggingFrame(NSRect(origin: .zero, size: iconSize), contents: icon)

        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    // MARK: - NSDraggingSource

    override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [] : .move
    }

    override func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Clear drag state
        controller?.selectionState.draggedFaceIDs.removeAll()
        controller?.selectionState.draggedGroupID = nil
        draggedFaceIDs = []
        draggedGroupID = nil
        refreshVisibleSelections()

        // Clear all highlights
        for item in visibleItems() {
            if let cardItem = item as? FaceGroupCardItem {
                cardItem.cardView.setHighlighted(false)
            }
            if let newItem = item as? FaceGroupNewGroupItem {
                newItem.setHighlighted(false)
            }
        }
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        return .move
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let location = convert(sender.draggingLocation, from: nil)

        // Clear all highlights first
        for item in visibleItems() {
            if let cardItem = item as? FaceGroupCardItem {
                cardItem.cardView.setHighlighted(false)
            }
            if let newItem = item as? FaceGroupNewGroupItem {
                newItem.setHighlighted(false)
            }
        }

        // Find item under cursor
        guard let indexPath = indexPathForItem(at: location),
              let item = self.item(at: indexPath) else {
            return .move
        }

        if let cardItem = item as? FaceGroupCardItem {
            // Don't highlight if dragging faces to their own group or dragging group onto itself
            if let draggedGroupID, cardItem.cardView.groupID == draggedGroupID {
                return []
            }
            cardItem.cardView.setHighlighted(true)
            return .move
        } else if let newItem = item as? FaceGroupNewGroupItem {
            newItem.setHighlighted(true)
            return .move
        }

        return .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        for item in visibleItems() {
            if let cardItem = item as? FaceGroupCardItem {
                cardItem.cardView.setHighlighted(false)
            }
            if let newItem = item as? FaceGroupNewGroupItem {
                newItem.setHighlighted(false)
            }
        }
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let controller else { return false }

        let location = convert(sender.draggingLocation, from: nil)
        guard let pasteboard = sender.draggingPasteboard.string(forType: .string) else { return false }

        // Determine target
        let indexPath = indexPathForItem(at: location)
        let targetItem = indexPath.flatMap { self.item(at: $0) }

        if pasteboard.hasPrefix("group:") {
            // Group merge
            let groupIDString = String(pasteboard.dropFirst(6))
            guard let sourceGroupID = UUID(uuidString: groupIDString) else { return false }

            if let cardItem = targetItem as? FaceGroupCardItem,
               let targetGroupID = cardItem.cardView.groupID,
               sourceGroupID != targetGroupID {
                controller.viewModel.mergeGroups(sourceID: sourceGroupID, into: targetGroupID)
                controller.selectionState.draggedGroupID = nil
                return true
            }
        } else {
            // Face IDs
            let ids = Set(pasteboard.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
            guard !ids.isEmpty else { return false }

            if let cardItem = targetItem as? FaceGroupCardItem, let targetGroupID = cardItem.cardView.groupID {
                // Move faces to existing group, filtering out faces already in target (O(1) lookup per face)
                let facesToMove = ids.filter { faceID in
                    controller.viewModel.face(byID: faceID)?.groupID != targetGroupID
                }
                controller.viewModel.moveFaces(Set(facesToMove), toGroup: targetGroupID)
            } else if targetItem is FaceGroupNewGroupItem {
                // Create new group
                controller.viewModel.createNewGroup(withFaces: ids)
            } else {
                return false
            }

            controller.selectionState.selectedFaceIDs.removeAll()
            controller.selectionState.draggedFaceIDs.removeAll()
            return true
        }

        return false
    }

    // MARK: - Mouse Click on Empty Area

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let location = convert(event.locationInWindow, from: nil)
        // If clicking empty space (no item), deselect
        if indexPathForItem(at: location) == nil {
            controller?.selectionState.selectedFaceIDs.removeAll()
            controller?.selectionState.focusedFaceID = nil
            refreshVisibleSelections()
        }
        // Don't call super — let card views handle their own mouse events
    }
}
