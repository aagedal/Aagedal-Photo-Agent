import SwiftUI

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
                    ThumbnailCell(
                        image: image,
                        isSelected: viewModel.selectedImageIDs.contains(image.url),
                        thumbnailService: viewModel.thumbnailService
                    )
                    .onTapGesture(count: 2) {
                        viewModel.selectedImageIDs = [image.url]
                        viewModel.isFullScreen = true
                    }
                    .onTapGesture {
                        // Check live modifier flags so CMD/Shift clicks
                        // are handled exclusively by the simultaneous gestures below
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
                }
            }
            .padding()
        }
        .focusable()
        .focused($isGridFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) {
            viewModel.selectPrevious()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            viewModel.selectNext()
            return .handled
        }
        .onKeyPress(.upArrow) {
            viewModel.selectPrevious()
            return .handled
        }
        .onKeyPress(.downArrow) {
            viewModel.selectNext()
            return .handled
        }
        .onKeyPress(.space) {
            guard viewModel.firstSelectedImage != nil else { return .ignored }
            viewModel.isFullScreen = true
            return .handled
        }
    }

    private func handleTap(image: ImageFile, modifiers: EventModifiers) {
        if modifiers.contains(.command) {
            if viewModel.selectedImageIDs.contains(image.url) {
                viewModel.selectedImageIDs.remove(image.url)
            } else {
                viewModel.selectedImageIDs.insert(image.url)
            }
        } else if modifiers.contains(.shift) {
            if let lastSelected = viewModel.selectedImageIDs.first,
               let lastIndex = viewModel.sortedImages.firstIndex(where: { $0.url == lastSelected }),
               let currentIndex = viewModel.sortedImages.firstIndex(where: { $0.url == image.url }) {
                let range = min(lastIndex, currentIndex)...max(lastIndex, currentIndex)
                for i in range {
                    viewModel.selectedImageIDs.insert(viewModel.sortedImages[i].url)
                }
            }
        } else {
            viewModel.selectedImageIDs = [image.url]
        }
    }
}
