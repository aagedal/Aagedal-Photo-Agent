import SwiftUI

/// Bridges the AppKit-based FaceGroupCollectionController into SwiftUI.
struct FaceGroupCollectionRepresentable: NSViewControllerRepresentable {
    let viewModel: FaceRecognitionViewModel
    let selectionState: FaceSelectionState
    let settingsViewModel: SettingsViewModel
    var callbacks: FaceGroupCardCallbacks
    /// True while the review sidebar is being live-resized — holds the grid layout steady so the
    /// cards don't stutter between column counts on every drag pixel.
    var isResizing: Bool = false

    func makeNSViewController(context: Context) -> FaceGroupCollectionController {
        let controller = FaceGroupCollectionController(
            viewModel: viewModel,
            selectionState: selectionState,
            settingsViewModel: settingsViewModel
        )
        controller.callbacks = callbacks
        return controller
    }

    func updateNSViewController(_ nsViewController: FaceGroupCollectionController, context: Context) {
        // Update callbacks in case closures changed
        nsViewController.callbacks = callbacks
        nsViewController.isResizing = isResizing
    }
}
