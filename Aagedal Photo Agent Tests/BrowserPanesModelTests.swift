import Foundation
import Observation
import Testing
@testable import Aagedal_Photo_Agent

/// `withObservationTracking`'s onChange is @Sendable; it fires synchronously inside the
/// mutating call on this test's actor, so the lock only satisfies the compiler.
private nonisolated final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

@Suite("Browser panes model")
@MainActor
struct BrowserPanesModelTests {
    private func makeModel() -> BrowserPanesModel {
        BrowserPanesModel(primary: BrowserViewModel(),
                          thumbnailService: ThumbnailService(),
                          fullScreenImageCache: FullScreenImageCache())
    }

    @Test func layoutSummariesFollowTabsSplitsAndClose() throws {
        let model = makeModel()
        let primary = BrowserPaneID(model.primary)
        #expect(model.visiblePaneIDs == [primary])
        #expect(model.groupCount == 1)

        let tab = try #require(model.addTab())
        #expect(model.visiblePaneIDs == [BrowserPaneID(tab)])
        #expect(model.groupCount == 1)

        let split = try #require(model.splitActive(.trailing))
        #expect(model.groupCount == 2)
        #expect(model.visiblePaneIDs == model.tree.visiblePaneIDs)
        #expect(model.visiblePaneIDs.contains(BrowserPaneID(split)))

        model.close(BrowserPaneID(split))
        #expect(model.groupCount == 1)
        #expect(model.visiblePaneIDs == model.tree.visiblePaneIDs)

        model.close(BrowserPaneID(tab))
        #expect(model.visiblePaneIDs == [primary])
    }

    /// A divider drag replaces `tree` every frame; views outside the grid read only the
    /// summaries, which must not invalidate while the arrangement itself is unchanged.
    @Test func resizingSplitsDoesNotInvalidateLayoutSummaries() throws {
        let model = makeModel()
        _ = try #require(model.splitActive(.trailing))
        guard case .split(let split) = model.tree.root else {
            Issue.record("expected a split root")
            return
        }

        let summariesChanged = Flag()
        withObservationTracking {
            _ = model.visiblePaneIDs
            _ = model.groupCount
        } onChange: {
            summariesChanged.set()
        }
        model.setFractions([0.3, 0.7], forSplit: split.id)
        model.setFractions([0.4, 0.6], forSplit: split.id)

        #expect(!summariesChanged.isSet)
        guard case .split(let resized) = model.tree.root else {
            Issue.record("expected a split root")
            return
        }
        #expect(resized.fractions == [0.4, 0.6])
    }
}
