import SwiftUI

/// Bridges the AppKit-based CollectionViewGridController into SwiftUI.
struct CollectionViewGridRepresentable: NSViewControllerRepresentable {
    let viewModel: BrowserViewModel

    func makeNSViewController(context: Context) -> CollectionViewGridController {
        CollectionViewGridController(viewModel: viewModel)
    }

    func updateNSViewController(_ nsViewController: CollectionViewGridController, context: Context) {
        // ViewModel reference is stable — observation handles all updates
    }
}
