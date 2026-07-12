import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Develop interaction behavior")
struct DevelopInteractionBehaviorTests {
    private let urls = (0..<5).map { URL(fileURLWithPath: "/tmp/image-\($0).jpg") }

    @Test("Deletion selects the next image when both neighbors are equally close")
    func deletionPrefersNextNeighbor() {
        let result = BrowserViewModel.closestSurvivingImageURL(
            in: urls,
            around: urls[2],
            deleting: [urls[2]]
        )

        #expect(result == urls[3])
    }

    @Test("Deletion searches past a deleted run to the actually closest neighbor")
    func deletionSearchesByOriginalDistance() {
        let result = BrowserViewModel.closestSurvivingImageURL(
            in: urls,
            around: urls[2],
            deleting: [urls[2], urls[3], urls[4]]
        )

        #expect(result == urls[1])
    }

    @Test("Deleting the final image selects its previous neighbor")
    func deletingFinalImageSelectsPrevious() {
        let result = BrowserViewModel.closestSurvivingImageURL(
            in: urls,
            around: urls[4],
            deleting: [urls[4]]
        )

        #expect(result == urls[3])
    }

    @Test("Brush axis follows the first dominant cursor direction")
    func brushAxisInference() {
        let start = CGPoint(x: 40, y: 50)

        #expect(BrushStrokeAxis.inferred(from: start, to: CGPoint(x: 70, y: 55)) == .horizontal)
        #expect(BrushStrokeAxis.inferred(from: start, to: CGPoint(x: 45, y: 80)) == .vertical)
    }

    @Test("Brush axis projection makes a perfectly straight line")
    func brushAxisProjection() {
        let start = CGPoint(x: 40, y: 50)
        let point = CGPoint(x: 70, y: 80)

        #expect(BrushStrokeAxis.horizontal.constrain(point, from: start) == CGPoint(x: 70, y: 50))
        #expect(BrushStrokeAxis.vertical.constrain(point, from: start) == CGPoint(x: 40, y: 80))
    }
}
