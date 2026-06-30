import SwiftUI

/// Bridges the AppKit-based CollectionViewGridController into SwiftUI.
struct CollectionViewGridRepresentable: NSViewControllerRepresentable {
    let viewModel: BrowserViewModel
    var onFocus: (() -> Void)? = nil

    func makeNSViewController(context: Context) -> CollectionViewGridController {
        let controller = CollectionViewGridController(viewModel: viewModel)
        controller.onFocus = onFocus
        return controller
    }

    func updateNSViewController(_ nsViewController: CollectionViewGridController, context: Context) {
        // ViewModel reference is stable — observation handles all updates
        nsViewController.onFocus = onFocus
    }
}
