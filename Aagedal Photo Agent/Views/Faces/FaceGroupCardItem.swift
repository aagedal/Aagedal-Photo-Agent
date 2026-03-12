import AppKit

final class FaceGroupCardItem: NSCollectionViewItem {

    static let identifier = NSUserInterfaceItemIdentifier("FaceGroupCardItem")

    private(set) var cardView: FaceGroupCardView!

    override func loadView() {
        cardView = FaceGroupCardView()
        self.view = cardView
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cardView.prepareForReuse()
    }

    func configure(group: FaceGroup, viewModel: FaceRecognitionViewModel, selectionState: FaceSelectionState,
                   settingsViewModel: SettingsViewModel, isExpanded: Bool, callbacks: FaceGroupCardCallbacks) {
        cardView.configure(
            group: group,
            viewModel: viewModel,
            selectionState: selectionState,
            settingsViewModel: settingsViewModel,
            isExpanded: isExpanded,
            callbacks: callbacks
        )
    }
}
