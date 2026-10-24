import SwiftUI

/// Bridges the AppKit-based CollectionViewGridController into SwiftUI.
struct CollectionViewGridRepresentable: NSViewControllerRepresentable {
    let viewModel: BrowserViewModel
    var onFocus: (() -> Void)? = nil
    var isActivePane: Bool = true
    var onImproveDescriptions: (() -> Void)? = nil
    var onExtractVideoStills: ((URL) -> Void)? = nil
    @Environment(AppCommandRouter.self) private var commandRouter

    func makeNSViewController(context: Context) -> CollectionViewGridController {
        let controller = CollectionViewGridController(
            viewModel: viewModel,
            commandRouter: commandRouter
        )
        controller.onFocus = onFocus
        controller.isActivePane = isActivePane
        controller.onImproveDescriptions = onImproveDescriptions
        controller.onExtractVideoStills = onExtractVideoStills
        return controller
    }

    func updateNSViewController(_ nsViewController: CollectionViewGridController, context: Context) {
        // ViewModel reference is stable — observation handles all updates
        nsViewController.onFocus = onFocus
        nsViewController.isActivePane = isActivePane
        nsViewController.onImproveDescriptions = onImproveDescriptions
        nsViewController.onExtractVideoStills = onExtractVideoStills
    }
}
