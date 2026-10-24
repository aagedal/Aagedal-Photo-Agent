import Foundation

/// Quit coverage for one browser pane's rating/label/rotate writes. Those writes run on the
/// pane's own FIFO (`BrowserViewModel.applyBrowserFieldMutation`), outside the metadata
/// editor's queue, so without this a quit could exit mid-batch and drop culling decisions.
///
/// Registered per pane (primary at window creation, a split/tab pane when it is created),
/// keyed per model like the other quit entries so two windows or two panes never replace each
/// other. The pane is held weakly: a gone pane has no running writes (its write task retains it).
@MainActor
enum BrowserFieldMutationTermination {
    static func register(
        _ pane: BrowserViewModel,
        flush: MetadataEditorTerminationFlush = .shared,
        monitor: BackgroundOperationMonitor = .shared
    ) {
        let id = ObjectIdentifier(pane).hashValue
        // The quit flush waits for queued writes before the editor stages run.
        flush.registerWait("fieldMutations-\(id)") { [weak pane] in
            await pane?.waitForPendingFieldMutationWrites()
        }
        // "Saving Changes…": "Ratings/labels: 120 remaining".
        flush.registerActivity("fieldMutationActivity-\(id)") { [weak pane] in
            pane?.fieldMutationActivityDescription.map { [$0] } ?? []
        }
        // Quit warning: "A rating/label write is still running."
        monitor.registerSource("fieldMutations-\(id)") { [weak pane] in
            pane?.hasFieldMutationWritesInFlight == true ? ["a rating/label write"] : []
        }
    }
}
