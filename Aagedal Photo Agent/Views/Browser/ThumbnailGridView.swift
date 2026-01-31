import SwiftUI
import UniformTypeIdentifiers

struct ThumbnailGridView: View {
    @Bindable var viewModel: BrowserViewModel
    @FocusState private var isGridFocused: Bool
    @State private var gridWidth: CGFloat = 0

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
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(viewModel.sortedImages) { image in
                        makeThumbnailCell(for: image)
                    }
                }
                .padding()
            }
            .onAppear {
                gridWidth = geometry.size.width
            }
            .onChange(of: geometry.size.width) { _, newWidth in
                gridWidth = newWidth
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
            // Only handle space when grid is focused (not when a text field has focus)
            guard isGridFocused, viewModel.firstSelectedImage != nil else { return .ignored }
            viewModel.isFullScreen = true
            return .handled
        }
        .onKeyPress("a") {
            // Only handle Cmd+A when grid is focused (not when a text field has focus)
            guard isGridFocused, NSEvent.modifierFlags.contains(.command) else { return .ignored }
            viewModel.selectAll()
            return .handled
        }
    }

    @ViewBuilder
    private func makeThumbnailCell(for image: ImageFile) -> some View {
        let baseCell = ThumbnailCell(
            image: image,
            isSelected: viewModel.selectedImageIDs.contains(image.url),
            thumbnailService: viewModel.thumbnailService,
            onDelete: {
                viewModel.deleteSelectedImages()
            }
        )
        .equatable()
        .onTapGesture(count: 2) {
            viewModel.selectedImageIDs = [image.url]
            viewModel.isFullScreen = true
        }
        .onTapGesture {
            let flags = NSEvent.modifierFlags
            if flags.contains(.command) {
                handleTap(image: image, modifiers: .command)
            } else if flags.contains(.shift) {
                handleTap(image: image, modifiers: .shift)
            } else {
                handleTap(image: image, modifiers: [])
            }
            isGridFocused = true
        }

        baseCell
            .onDrag {
                if viewModel.sortOrder != .manual {
                    viewModel.initializeManualOrder(from: viewModel.sortedImages)
                    viewModel.sortOrder = .manual
                }
                // If dragging a selected image, drag all selected images together
                if viewModel.selectedImageIDs.contains(image.url) && viewModel.selectedImageIDs.count > 1 {
                    viewModel.draggedImageURLs = viewModel.selectedImageIDs
                } else {
                    viewModel.draggedImageURLs = [image.url]
                }
                return NSItemProvider(object: image.url as NSURL)
            }
            .onDrop(of: [.fileURL], delegate: ImageReorderDelegate(
                targetURL: image.url,
                viewModel: viewModel
            ))
    }

    private func handleTap(image: ImageFile, modifiers: EventModifiers) {
        if modifiers.contains(.command) {
            // CMD-click: Toggle individual selection (full assignment for reliable change detection)
            var updated = viewModel.selectedImageIDs
            if updated.contains(image.url) {
                updated.remove(image.url)
            } else {
                updated.insert(image.url)
            }
            viewModel.selectedImageIDs = updated
            viewModel.lastClickedImageURL = image.url
        } else if modifiers.contains(.shift) {
            // SHIFT-click: Range selection from last clicked anchor
            let anchor = viewModel.lastClickedImageURL ?? viewModel.selectedImageIDs.first
            if let anchor,
               let anchorIndex = viewModel.urlToSortedIndex[anchor],
               let currentIndex = viewModel.urlToSortedIndex[image.url] {
                let sorted = viewModel.sortedImages
                var updated = viewModel.selectedImageIDs
                let range = min(anchorIndex, currentIndex)...max(anchorIndex, currentIndex)
                for i in range {
                    updated.insert(sorted[i].url)
                }
                viewModel.selectedImageIDs = updated
            }
            // Don't update lastClickedImageURL — anchor stays for subsequent shift-clicks
        } else {
            // Regular click: Single selection
            viewModel.selectedImageIDs = [image.url]
            viewModel.lastClickedImageURL = image.url
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
            if let newTargetIndex = viewModel.manualOrder.firstIndex(of: targetURL) {
                // Insert after target if we were originally below it, before if above
                let firstDraggedOriginalIndex = draggedIndices.first!
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
