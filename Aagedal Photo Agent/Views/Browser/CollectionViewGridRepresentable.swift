import SwiftUI

/// Bridges the AppKit-based CollectionViewGridController into SwiftUI.
struct CollectionViewGridRepresentable: NSViewControllerRepresentable {
    let viewModel: BrowserViewModel
    var onFocus: (() -> Void)? = nil
    var onImproveDescriptions: (() -> Void)? = nil
    @Environment(AppCommandRouter.self) private var commandRouter

    func makeNSViewController(context: Context) -> CollectionViewGridController {
        let controller = CollectionViewGridController(
            viewModel: viewModel,
            commandRouter: commandRouter
        )
        controller.onFocus = onFocus
        controller.onImproveDescriptions = onImproveDescriptions
        return controller
    }

    func updateNSViewController(_ nsViewController: CollectionViewGridController, context: Context) {
        // ViewModel reference is stable — observation handles all updates
        nsViewController.onFocus = onFocus
        nsViewController.onImproveDescriptions = onImproveDescriptions
    }
}
