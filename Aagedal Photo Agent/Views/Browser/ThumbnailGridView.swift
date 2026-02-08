import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ThumbnailGridView: View {
    @Bindable var viewModel: BrowserViewModel
    @FocusState private var isGridFocused: Bool
    @State private var gridWidth: CGFloat = 0
    @State private var dragCoordinator = ThumbnailDragCoordinator()

    private let columns = [
        GridItem(.adaptive(minimum: 190, maximum: 250), spacing: 8)
    ]

    private let itemMinWidth: CGFloat = 190
    private let itemMaxWidth: CGFloat = 250
    private let itemSpacing: CGFloat = 8
    private let gridPadding: CGFloat = 16 // .padding() default

    /// Calculate the number of columns based on the current grid width
    private var columnCount: Int {
        guard gridWidth > 0 else { return 1 }
        let availableWidth = gridWidth - gridPadding * 2
        // With adaptive columns, SwiftUI fits as many items as possible with minimum width
        let count = Int((availableWidth + itemSpacing) / (itemMinWidth + itemSpacing))
        return max(count, 1)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(viewModel.visibleImages) { image in
                            makeThumbnailCell(for: image)
                                .id(image.url)
                        }
                    }
                    .padding()
                }
                .onAppear {
                    gridWidth = geometry.size.width
                    scrollToSelectionIfNeeded(proxy)
                    setupDragCoordinator()
                }
                .onChange(of: geometry.size.width) { _, newWidth in
                    gridWidth = newWidth
                }
                .onChange(of: viewModel.lastClickedImageURL) { _, newValue in
                    scrollToSelectionIfNeeded(proxy)
                    if newValue != nil {
                        isGridFocused = true
                    }
                }
            }
        }
        .focusable()
        .focused($isGridFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) {
            viewModel.selectPrevious(extending: NSEvent.modifierFlags.contains(.shift))
            return .handled
        }
        .onKeyPress(.rightArrow) {
            viewModel.selectNext(extending: NSEvent.modifierFlags.contains(.shift))
            return .handled
        }
        .onKeyPress(.upArrow) {
            viewModel.selectUp(columns: columnCount, extending: NSEvent.modifierFlags.contains(.shift))
            return .handled
        }
        .onKeyPress(.downArrow) {
            viewModel.selectDown(columns: columnCount, extending: NSEvent.modifierFlags.contains(.shift))
            return .handled
        }
        .onKeyPress(.space) {
            // Only handle space when no text field is active
            guard viewModel.firstSelectedImage != nil,
                  !isTextFieldActive() else { return .ignored }
            viewModel.isFullScreen = true
            return .handled
        }
        .onKeyPress("a") {
            // Only handle Cmd+A when grid is focused (not when a text field has focus)
            guard isGridFocused, NSEvent.modifierFlags.contains(.command) else { return .ignored }
            viewModel.selectAll()
            return .handled
        }
        .onKeyPress(keys: [KeyEquivalent("f")]) { press in
            guard press.modifiers.contains(.command),
                  viewModel.firstSelectedImage != nil else {
                return .ignored
            }
            viewModel.isFullScreen.toggle()
            return .handled
        }
    }

    @ViewBuilder
    private func makeThumbnailCell(for image: ImageFile) -> some View {
        let selectedURLs = viewModel.selectedImageIDs.contains(image.url)
            ? viewModel.selectedImages.map(\.url)
            : [image.url]

        let baseCell = ThumbnailCell(
            image: image,
            isSelected: viewModel.selectedImageIDs.contains(image.url),
            thumbnailService: viewModel.thumbnailService,
            onDelete: {
                viewModel.confirmDeleteSelectedImages()
            },
            onAddToSubfolder: {
                if !viewModel.selectedImageIDs.contains(image.url) {
                    viewModel.selectedImageIDs = [image.url]
                    viewModel.lastClickedImageURL = image.url
                }
                viewModel.promptAddSelectedImagesToSubfolder()
            },
            onRevealInFinder: {
                if selectedURLs.count > 1 {
                    NSWorkspace.shared.activateFileViewerSelecting(selectedURLs)
                } else {
                    NSWorkspace.shared.selectFile(image.url.path, inFileViewerRootedAtPath: image.url.deletingLastPathComponent().path)
                }
            },
            onOpenInExternalEditor: {
                if let editorPath = UserDefaults.standard.string(forKey: UserDefaultsKeys.defaultExternalEditor),
                   !editorPath.isEmpty {
                    NSWorkspace.shared.open(
                        selectedURLs,
                        withApplicationAt: URL(fileURLWithPath: editorPath),
                        configuration: NSWorkspace.OpenConfiguration()
                    )
                }
            },
            onCopyFilePaths: {
                let paths = selectedURLs.map(\.path).joined(separator: "\n")
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(paths, forType: .string)
            }
        )
        .equatable()

        baseCell
            .overlay(
                ThumbnailDragSource(
                    itemURL: image.url,
                    coordinator: dragCoordinator
                )
            )
            .onDrop(of: [.fileURL], delegate: ImageReorderDelegate(
                targetURL: image.url,
                viewModel: viewModel
            ))
    }

    private func setupDragCoordinator() {
        let vm = viewModel
        dragCoordinator.selectionProvider = {
            vm.visibleImages
                .filter { vm.selectedImageIDs.contains($0.url) }
                .map(\.url)
        }
        dragCoordinator.onClick = { url, clickCount, modifiers in
            if clickCount == 2 {
                vm.selectedImageIDs = [url]
                vm.lastClickedImageURL = url
                vm.isFullScreen = true
            } else if modifiers.contains(.command) {
                var updated = vm.selectedImageIDs
                if updated.contains(url) {
                    updated.remove(url)
                } else {
                    updated.insert(url)
                }
                vm.selectedImageIDs = updated
                vm.lastClickedImageURL = url
            } else if modifiers.contains(.shift) {
                let anchor = vm.lastClickedImageURL ?? vm.selectedImageIDs.first
                if let anchor,
                   let anchorIndex = vm.urlToVisibleIndex[anchor],
                   let currentIndex = vm.urlToVisibleIndex[url] {
                    let range = min(anchorIndex, currentIndex)...max(anchorIndex, currentIndex)
                    var updated = vm.selectedImageIDs
                    updated.reserveCapacity(updated.count + range.count)
                    updated.formUnion(vm.visibleImages[range].lazy.map(\.url))
                    vm.selectedImageIDs = updated
                }
            } else {
                vm.selectedImageIDs = [url]
                vm.lastClickedImageURL = url
            }
        }
        dragCoordinator.onDragStart = { urls in
            if vm.sortOrder != .manual {
                vm.initializeManualOrder(from: vm.sortedImages)
                vm.sortOrder = .manual
            }
            vm.draggedImageURLs = Set(urls)
        }
        dragCoordinator.onDragEnd = {
            vm.draggedImageURLs = []
        }
        dragCoordinator.thumbnailProvider = { url in
            vm.thumbnailService.thumbnail(for: url)
        }
    }

    /// Check if a text field currently has keyboard focus
    private func isTextFieldActive() -> Bool {
        guard let window = NSApp.keyWindow else { return false }
        // Check if the first responder is a text editing view
        if let responder = window.firstResponder {
            return responder is NSText || responder is NSTextView
        }
        return false
    }

    private func scrollToSelectionIfNeeded(_ proxy: ScrollViewProxy) {
        guard let target = viewModel.lastClickedImageURL,
              viewModel.urlToVisibleIndex[target] != nil else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            proxy.scrollTo(target, anchor: .center)
        }
    }

}

// MARK: - Drag Coordinator

private final class ThumbnailDragCoordinator {
    var selectionProvider: () -> [URL] = { [] }
    var onClick: (URL, Int, NSEvent.ModifierFlags) -> Void = { _, _, _ in }
    var onDragStart: ([URL]) -> Void = { _ in }
    var onDragEnd: () -> Void = {}
    var thumbnailProvider: (URL) -> NSImage? = { _ in nil }
}

// MARK: - Drag Source (multi-file export)

private struct ThumbnailDragSource: NSViewRepresentable {
    let itemURL: URL
    let coordinator: ThumbnailDragCoordinator

    func makeNSView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        view.itemURL = itemURL
        view.coordinator = coordinator
        return view
    }

    func updateNSView(_ nsView: DragSourceView, context: Context) {
        nsView.itemURL = itemURL
    }

    final class DragSourceView: NSView, NSDraggingSource {
        var itemURL: URL?
        var coordinator: ThumbnailDragCoordinator?

        private static var extensionIconCache: [String: NSImage] = [:]

        private var isDragging = false
        private var mouseDownLocation: NSPoint?

        override func mouseDown(with event: NSEvent) {
            mouseDownLocation = event.locationInWindow
            isDragging = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard !isDragging, let start = mouseDownLocation else {
                return
            }

            let deltaX = abs(event.locationInWindow.x - start.x)
            let deltaY = abs(event.locationInWindow.y - start.y)
            if deltaX < 3 && deltaY < 3 {
                nextResponder?.mouseDragged(with: event)
                return
            }

            guard let itemURL, let coordinator else { return }
            let selection = coordinator.selectionProvider()
            let urls: [URL]
            if selection.contains(itemURL) && selection.count > 1 {
                urls = selection
            } else {
                urls = [itemURL]
            }

            isDragging = true
            coordinator.onDragStart(urls)

            let items = makeDraggingItems(for: urls)
            beginDraggingSession(with: items, event: event, source: self)
        }

        override func mouseUp(with event: NSEvent) {
            mouseDownLocation = nil
            if !isDragging, let itemURL {
                // Dismiss any active text field before handling click
                if let responder = window?.firstResponder,
                   responder is NSText || responder is NSTextView {
                    window?.makeFirstResponder(nil)
                }
                coordinator?.onClick(itemURL, event.clickCount, event.modifierFlags)
            }
            isDragging = false
        }

        override func rightMouseDown(with event: NSEvent) {
            nextResponder?.rightMouseDown(with: event)
        }

        override func rightMouseUp(with event: NSEvent) {
            nextResponder?.rightMouseUp(with: event)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? .copy : .move
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            isDragging = false
            coordinator?.onDragEnd()
        }

        private func makeDraggingItems(for urls: [URL]) -> [NSDraggingItem] {
            var items: [NSDraggingItem] = []
            let baseFrame = bounds
            let maxVisualItems = 5

            for (index, url) in urls.enumerated() {
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)

                if index < maxVisualItems {
                    let icon = dragIcon(for: url)
                    icon.size = NSSize(width: 64, height: 64)
                    let offset = CGFloat(index) * 6
                    let frame = baseFrame.offsetBy(dx: offset, dy: -offset)
                    item.setDraggingFrame(frame, contents: icon)
                }

                items.append(item)
            }

            return items
        }

        private func dragIcon(for url: URL) -> NSImage {
            // Try cached thumbnail first (O(1) NSCache lookup)
            if let thumbnail = coordinator?.thumbnailProvider(url) {
                return thumbnail
            }
            // Fall back to cached per-extension icon
            let ext = url.pathExtension.lowercased()
            if let cached = DragSourceView.extensionIconCache[ext] {
                return cached
            }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            DragSourceView.extensionIconCache[ext] = icon
            return icon
        }
    }
}

// MARK: - Drop Delegate for Manual Reorder

struct ImageReorderDelegate: DropDelegate {
    let targetURL: URL
    let viewModel: BrowserViewModel

    func performDrop(info: DropInfo) -> Bool {
        viewModel.draggedImageURLs = []
        return true
    }

    func dropEntered(info: DropInfo) {
        let draggedURLs = viewModel.draggedImageURLs
        guard !draggedURLs.isEmpty,
              !draggedURLs.contains(targetURL) else { return }

        guard let toIndex = viewModel.manualOrder.firstIndex(of: targetURL) else { return }

        // Collect indices of all dragged items, sorted in their current order
        let draggedIndices = viewModel.manualOrder.enumerated()
            .filter { draggedURLs.contains($0.element) }
            .map(\.offset)
        guard !draggedIndices.isEmpty else { return }

        withAnimation(.default) {
            // Remove dragged items from their current positions (back to front to preserve indices)
            var draggedItems: [URL] = []
            for index in draggedIndices.reversed() {
                draggedItems.insert(viewModel.manualOrder.remove(at: index), at: 0)
            }

            // Find the new insertion point (target may have shifted after removals)
            let insertionIndex: Int
            if let newTargetIndex = viewModel.manualOrder.firstIndex(of: targetURL),
               let firstDraggedOriginalIndex = draggedIndices.first {
                // Insert after target if we were originally below it, before if above
                insertionIndex = firstDraggedOriginalIndex > toIndex ? newTargetIndex : newTargetIndex + 1
            } else {
                insertionIndex = viewModel.manualOrder.endIndex
            }

            viewModel.manualOrder.insert(contentsOf: draggedItems, at: insertionIndex)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        true
    }
}
