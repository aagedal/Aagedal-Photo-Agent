import SwiftUI
import UniformTypeIdentifiers

struct ThumbnailGridView: View {
    @Bindable var viewModel: BrowserViewModel
    @FocusState private var isGridFocused: Bool

    private let columns = [
        GridItem(.adaptive(minimum: 190, maximum: 250), spacing: 8)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(viewModel.sortedImages) { image in
                    makeThumbnailCell(for: image)
                }
            }
            .padding()
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
            viewModel.selectPrevious(extending: NSEvent.modifierFlags.contains(.shift))
            return .handled
        }
        .onKeyPress(.downArrow) {
            viewModel.selectNext(extending: NSEvent.modifierFlags.contains(.shift))
            return .handled
        }
        .onKeyPress(.space) {
            guard viewModel.firstSelectedImage != nil else { return .ignored }
            viewModel.isFullScreen = true
            return .handled
        }
    }

    @ViewBuilder
    private func makeThumbnailCell(for image: ImageFile) -> some View {
        let baseCell = ThumbnailCell(
            image: image,
            isSelected: viewModel.selectedImageIDs.contains(image.url),
            thumbnailService: viewModel.thumbnailService
        )
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
                viewModel.draggedImageURL = image.url
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
               let anchorIndex = viewModel.sortedImages.firstIndex(where: { $0.url == anchor }),
               let currentIndex = viewModel.sortedImages.firstIndex(where: { $0.url == image.url }) {
                var updated = viewModel.selectedImageIDs
                let range = min(anchorIndex, currentIndex)...max(anchorIndex, currentIndex)
                for i in range {
                    updated.insert(viewModel.sortedImages[i].url)
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
        viewModel.draggedImageURL = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let draggedURL = viewModel.draggedImageURL,
              draggedURL != targetURL else { return }

        guard let fromIndex = viewModel.manualOrder.firstIndex(of: draggedURL),
              let toIndex = viewModel.manualOrder.firstIndex(of: targetURL),
              fromIndex != toIndex else { return }

        withAnimation(.default) {
            viewModel.manualOrder.move(
                fromOffsets: IndexSet(integer: fromIndex),
                toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
            )
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        true
    }
}
