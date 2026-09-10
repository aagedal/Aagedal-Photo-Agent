import AppKit
import Foundation

/// Formats commit evidence without inferring whether an uncertain filesystem operation succeeded.
/// All paths and recovery instructions supplied by the worker remain available to copy.
nonisolated struct TrashOperationFeedback: Sendable, Equatable {
    static let recoveryGuidance = "Photos with a linked voice memo move together in a named folder. To recover them, move the entire folder out of Finder’s Trash and open that folder in this app. Keep its contents together."

    let summary: String
    let details: String

    var message: String { summary + "\n\n" + details }

    init?(
        completedURLs: Set<URL>,
        failures: [FileSystemService.ItemFailure],
        cancelled: Bool,
        faceDataDisposition: FaceGroupDeletionResult.FaceDataDisposition? = nil
    ) {
        let faceDataNeedsAttention = faceDataDisposition.map { $0 != .applied } ?? false
        guard !failures.isEmpty || cancelled || faceDataNeedsAttention else { return nil }

        summary = "\(completedURLs.count) photo(s) moved to Trash; \(failures.count) issue(s) need attention."
        var paragraphs: [String] = []
        if cancelled {
            paragraphs.append("The operation stopped before all remaining photos were processed. Completed moves are listed in the count above.")
        }
        if let faceDataDisposition {
            switch faceDataDisposition {
            case .applied:
                paragraphs.append("The requested face data was removed from the app, including faces from any photos whose move to Trash failed. Read each photo’s result below.")
            case .groupNotFound:
                paragraphs.append("The face group was no longer available. No photos or face data were changed by this request.")
            case .cancelledBeforeMutation:
                paragraphs.append("The request was cancelled before changing the face data.")
            case .staleStatePreserved:
                paragraphs.append("The face data changed while the photos were being processed. The newer face data was preserved; review the group and the completed photo moves.")
            }
        }
        paragraphs += failures.map { failure in
            let status: String
            if completedURLs.contains(failure.sourceURL) {
                status = failure.stage == .cleanup
                    ? "Photo moved to Trash; cleanup needs attention"
                    : "Photo moved to Trash; related operation needs attention"
            } else {
                // An exception may describe an uncertain outcome after the system Trash call.
                // Do not promise that the original is still present or has been restored.
                status = "Move to Trash was not confirmed"
            }
            return "\(failure.sourceURL.path)\n\(status): \(failure.message)"
        }
        details = paragraphs.joined(separator: "\n\n")
    }

    init?(result: FaceGroupDeletionResult) {
        self.init(
            completedURLs: result.trashedPhotoURLs,
            failures: result.failures,
            cancelled: result.cancellationStoppedRemainingPhotos,
            faceDataDisposition: result.faceDataDisposition
        )
    }
}

/// Window-owned presentation survives removal of the face-group popover that initiated Trash.
/// A native, scrollable text view exposes every recovery path to accessibility and copying.
@MainActor
enum OperationIssueDetailsPresenter {
    static func present(title: String, message: String) {
        // End any current menu/popover event before presenting a sheet on the main window.
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = "Review the complete details below. You can select and copy this text."
            alert.addButton(withTitle: "Done")

            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 280))
            scrollView.hasVerticalScroller = true
            scrollView.borderType = .bezelBorder
            let textView = NSTextView(frame: scrollView.contentView.bounds)
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.font = .systemFont(ofSize: NSFont.systemFontSize)
            textView.textContainerInset = NSSize(width: 8, height: 8)
            textView.minSize = NSSize(width: 0, height: 0)
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.textContainer?.containerSize = NSSize(
                width: scrollView.contentSize.width,
                height: .greatestFiniteMagnitude
            )
            textView.textContainer?.widthTracksTextView = true
            textView.string = message
            textView.setAccessibilityLabel("Complete operation details")
            textView.setAccessibilityIdentifier("operation.issueDetails")
            scrollView.documentView = textView
            alert.accessoryView = scrollView

            if let window = NSApp.mainWindow ?? NSApp.keyWindow {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }

    static func presentTrashIssues(_ result: FaceGroupDeletionResult) {
        guard let feedback = TrashOperationFeedback(result: result) else { return }
        present(title: "Trash Needs Attention", message: feedback.message)
    }
}
