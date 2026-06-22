import Testing
import Foundation
@testable import Aagedal_Photo_Agent

/// `NormalizedCropRegion` is pure geometry on normalized [0,1]² coordinates. These tests
/// pin down the invariants the crop tool relies on: clamping never escapes bounds, moves
/// preserve dimensions, aspect-ratio resizes preserve area, and rotation-fitting preserves
/// the crop's center and aspect ratio while shrinking to keep every rotated corner in frame.
@Suite("NormalizedCropRegion")
struct NormalizedCropRegionTests {

    private let eps = 1e-9

    private func isWithinBounds(_ r: NormalizedCropRegion, tol: Double = 1e-9) -> Bool {
        r.left >= -tol && r.top >= -tol && r.right <= 1 + tol && r.bottom <= 1 + tol
            && r.right >= r.left && r.bottom >= r.top
    }

    // MARK: - Basic geometry

    @Test("Derived geometry of the full region")
    func fullGeometry() {
        let r = NormalizedCropRegion.full
        #expect(r.width == 1)
        #expect(r.height == 1)
        #expect(r.centerX == 0.5)
        #expect(r.centerY == 0.5)
    }

    @Test("width/height/center are derived from the edges")
    func derivedGeometry() {
        let r = NormalizedCropRegion(top: 0.2, left: 0.1, bottom: 0.6, right: 0.5)
        #expect(abs(r.width - 0.4) < eps)
        #expect(abs(r.height - 0.4) < eps)
        #expect(abs(r.centerX - 0.3) < eps)
        #expect(abs(r.centerY - 0.4) < eps)
    }

    // MARK: - clamped()

    @Test("A valid in-bounds region is unchanged by clamping")
    func clampLeavesValidRegion() {
        let r = NormalizedCropRegion(top: 0.25, left: 0.25, bottom: 0.75, right: 0.75)
        #expect(r.clamped() == r)
    }

    @Test("An out-of-bounds region is pulled back inside [0,1]")
    func clampPullsInBounds() {
        let r = NormalizedCropRegion(top: -0.2, left: -0.1, bottom: 1.2, right: 1.1).clamped()
        #expect(isWithinBounds(r))
        #expect(r == .full)
    }

    @Test("A zero-size region is grown to at least minSize")
    func clampEnforcesMinSize() {
        let r = NormalizedCropRegion(top: 0.5, left: 0.5, bottom: 0.5, right: 0.5).clamped()
        #expect(abs(r.width - 0.03) < eps)
        #expect(abs(r.height - 0.03) < eps)
        #expect(isWithinBounds(r))
    }

    @Test("minSize is honored at the far edge without escaping bounds")
    func clampMinSizeAtEdge() {
        // Degenerate region pinned to the bottom-right corner.
        let r = NormalizedCropRegion(top: 1.0, left: 1.0, bottom: 1.0, right: 1.0).clamped(minSize: 0.05)
        #expect(isWithinBounds(r))
        #expect(r.width >= 0.05 - eps)
        #expect(r.height >= 0.05 - eps)
    }

    // MARK: - movedBy()

    @Test("Moving within bounds shifts the rectangle and preserves size")
    func moveWithinBounds() {
        let r = NormalizedCropRegion(top: 0.1, left: 0.1, bottom: 0.3, right: 0.3)
        let moved = r.movedBy(dx: 0.2, dy: 0.1)
        #expect(abs(moved.left - 0.3) < eps)
        #expect(abs(moved.top - 0.2) < eps)
        #expect(abs(moved.width - 0.2) < eps)
        #expect(abs(moved.height - 0.2) < eps)
    }

    @Test("Moving past an edge clamps but keeps the dimensions")
    func moveClampsAtEdge() {
        let r = NormalizedCropRegion(top: 0.1, left: 0.1, bottom: 0.3, right: 0.3) // 0.2 x 0.2
        let moved = r.movedBy(dx: 1.0, dy: 1.0)
        #expect(isWithinBounds(moved))
        #expect(abs(moved.width - 0.2) < eps)
        #expect(abs(moved.height - 0.2) < eps)
        // Pinned to the far corner.
        #expect(abs(moved.right - 1.0) < eps)
        #expect(abs(moved.bottom - 1.0) < eps)
    }

    @Test("Moving against the origin clamps to 0 and keeps dimensions")
    func moveClampsAtOrigin() {
        let r = NormalizedCropRegion(top: 0.1, left: 0.1, bottom: 0.3, right: 0.3)
        let moved = r.movedBy(dx: -1.0, dy: -1.0)
        #expect(abs(moved.left) < eps)
        #expect(abs(moved.top) < eps)
        #expect(abs(moved.width - 0.2) < eps)
        #expect(abs(moved.height - 0.2) < eps)
    }

    // MARK: - resizedToAspectRatio()

    @Test("Resizing to a ratio preserves area and yields the target ratio (when unclamped)")
    func resizePreservesArea() {
        let r = NormalizedCropRegion(top: 0.25, left: 0.25, bottom: 0.75, right: 0.75) // 0.5 x 0.5
        let area = r.width * r.height
        let resized = r.resizedToAspectRatio(2.0)
        #expect(abs(resized.width * resized.height - area) < 1e-6)
        #expect(abs(resized.width / resized.height - 2.0) < 1e-6)
        // Center is preserved.
        #expect(abs(resized.centerX - 0.5) < 1e-6)
        #expect(abs(resized.centerY - 0.5) < 1e-6)
        #expect(isWithinBounds(resized, tol: 1e-6))
    }

    @Test("Resizing a region whose target would overflow shrinks to fit bounds")
    func resizeShrinksToFit() {
        // Nearly-full square asked for a very wide ratio cannot keep its area.
        let r = NormalizedCropRegion(top: 0.05, left: 0.05, bottom: 0.95, right: 0.95)
        let resized = r.resizedToAspectRatio(5.0)
        #expect(isWithinBounds(resized, tol: 1e-6))
        // Ratio is still applied even though area had to shrink.
        #expect(abs(resized.width / resized.height - 5.0) < 1e-3)
    }

    @Test("Resizing rejects non-positive ratios")
    func resizeRejectsBadRatio() {
        let r = NormalizedCropRegion(top: 0.25, left: 0.25, bottom: 0.75, right: 0.75)
        #expect(r.resizedToAspectRatio(0) == r)
        #expect(r.resizedToAspectRatio(-1) == r)
    }

    // MARK: - resizedToActualAspectRatio()

    @Test("Actual-aspect resize divides target by image aspect ratio")
    func actualAspectDelegates() {
        let r = NormalizedCropRegion(top: 0.25, left: 0.25, bottom: 0.75, right: 0.75)
        // With a square image (ar = 1) the actual ratio is the normalized ratio.
        let viaActual = r.resizedToActualAspectRatio(2.0, imageAspectRatio: 1.0)
        let viaNormalized = r.resizedToAspectRatio(2.0)
        #expect(viaActual == viaNormalized)

        // With a 2:1 image, a visible 2:1 crop needs a square normalized rect.
        let square = r.resizedToActualAspectRatio(2.0, imageAspectRatio: 2.0)
        #expect(abs(square.width / square.height - 1.0) < 1e-6)
    }

    @Test("Actual-aspect resize rejects degenerate inputs")
    func actualAspectRejectsBadInput() {
        let r = NormalizedCropRegion(top: 0.25, left: 0.25, bottom: 0.75, right: 0.75)
        #expect(r.resizedToActualAspectRatio(0, imageAspectRatio: 1.0) == r)
        #expect(r.resizedToActualAspectRatio(2.0, imageAspectRatio: 0) == r)
    }

    // MARK: - constrainedToAspectRatio()

    @Test("Constraining a wide crop to square shrinks width, keeps height, center-anchored")
    func constrainShrinksWidth() {
        let r = NormalizedCropRegion(top: 0.1, left: 0.1, bottom: 0.5, right: 0.9) // 0.8 x 0.4
        let c = r.constrainedToAspectRatio(1.0) // square
        #expect(abs(c.width - 0.4) < 1e-9)
        #expect(abs(c.height - 0.4) < 1e-9)
        // Height edges unchanged; width centered within the old bounds.
        #expect(abs(c.top - 0.1) < 1e-9)
        #expect(abs(c.centerX - 0.5) < 1e-9)
        #expect(isWithinBounds(c))
    }

    @Test("Constraining a tall crop to square shrinks height")
    func constrainShrinksHeight() {
        let r = NormalizedCropRegion(top: 0.1, left: 0.1, bottom: 0.9, right: 0.5) // 0.4 x 0.8
        let c = r.constrainedToAspectRatio(1.0)
        #expect(abs(c.width - 0.4) < 1e-9)
        #expect(abs(c.height - 0.4) < 1e-9)
        #expect(isWithinBounds(c))
    }

    @Test("Anchor 0 keeps the leading edge fixed")
    func constrainAnchorLeading() {
        let r = NormalizedCropRegion(top: 0.1, left: 0.1, bottom: 0.5, right: 0.9) // wide
        let c = r.constrainedToAspectRatio(1.0, anchorX: 0, anchorY: 0)
        // Left/top stay put when anchored to 0.
        #expect(abs(c.left - 0.1) < 1e-9)
        #expect(abs(c.top - 0.1) < 1e-9)
    }

    @Test("Constraining never grows beyond the original rectangle")
    func constrainOnlyShrinks() {
        let r = NormalizedCropRegion(top: 0.2, left: 0.2, bottom: 0.6, right: 0.8)
        let c = r.constrainedToAspectRatio(3.0)
        #expect(c.width <= r.width + 1e-9)
        #expect(c.height <= r.height + 1e-9)
    }

    // MARK: - fittingRotated()

    @Test("Zero rotation is equivalent to clamping")
    func fitZeroAngle() {
        let r = NormalizedCropRegion(top: 0.25, left: 0.25, bottom: 0.75, right: 0.75)
        #expect(r.fittingRotated(angleDegrees: 0, aspectRatio: 1.5) == r.clamped())
    }

    @Test("A small centered crop under mild rotation needs no shrink")
    func fitSmallCropUnchanged() {
        let r = NormalizedCropRegion(top: 0.4, left: 0.4, bottom: 0.6, right: 0.6)
        let fitted = r.fittingRotated(angleDegrees: 10, aspectRatio: 1.0)
        #expect(fitted == r)
    }

    @Test("A large rotated crop shrinks uniformly, preserving center and aspect")
    func fitLargeCropShrinks() {
        let r = NormalizedCropRegion(top: 0.05, left: 0.05, bottom: 0.95, right: 0.95) // 0.9 square
        let fitted = r.fittingRotated(angleDegrees: 20, aspectRatio: 1.0)
        // Must have shrunk to keep rotated corners in frame.
        #expect(fitted.width < r.width)
        // Square crop with ar = 1 stays square after uniform scaling.
        #expect(abs(fitted.width - fitted.height) < 1e-9)
        // Center preserved.
        #expect(abs(fitted.centerX - 0.5) < 1e-9)
        #expect(abs(fitted.centerY - 0.5) < 1e-9)
        #expect(isWithinBounds(fitted, tol: 1e-6))
    }

    // MARK: - centerClampedForRotation()

    @Test("Center-clamping never changes the crop dimensions")
    func centerClampPreservesDimensions() {
        let r = NormalizedCropRegion(top: 0.0, left: 0.0, bottom: 0.3, right: 0.3) // at the corner
        for angle in [0.0, 15.0, -30.0, 45.0] {
            let c = r.centerClampedForRotation(angleDegrees: angle, aspectRatio: 1.5)
            #expect(abs(c.width - r.width) < 1e-9, "width changed at \(angle)°")
            #expect(abs(c.height - r.height) < 1e-9, "height changed at \(angle)°")
        }
    }

    @Test("At zero angle the center is clamped so the rect fits in bounds")
    func centerClampZeroAngle() {
        let r = NormalizedCropRegion(top: -0.1, left: -0.1, bottom: 0.1, right: 0.1) // 0.2, off-screen
        let c = r.centerClampedForRotation(angleDegrees: 0, aspectRatio: 1.0)
        #expect(isWithinBounds(c))
        // The smallest in-bounds placement of a 0.2 crop puts its left/top at 0.
        #expect(abs(c.left) < 1e-9)
        #expect(abs(c.top) < 1e-9)
    }

    // MARK: - CropAspectRatio

    @Test("Aspect ratio enum exposes the expected numeric values")
    func aspectRatioValues() {
        #expect(CropAspectRatio.free.value == nil)
        #expect(CropAspectRatio.original.value == nil)
        #expect(CropAspectRatio.square.value == 1.0)
        #expect(abs((CropAspectRatio.ratio16x9.value ?? 0) - 16.0 / 9.0) < eps)
        #expect(abs((CropAspectRatio.ratio2x3.value ?? 0) - 2.0 / 3.0) < eps)
    }

    @Test("Portrait/landscape pairs are reciprocals")
    func aspectRatioReciprocals() {
        let pairs: [(CropAspectRatio, CropAspectRatio)] = [
            (.ratio3x2, .ratio2x3),
            (.ratio4x3, .ratio3x4),
            (.ratio16x9, .ratio9x16),
            (.ratio7x5, .ratio5x7)
        ]
        for (landscape, portrait) in pairs {
            guard let l = landscape.value, let p = portrait.value else {
                Issue.record("Missing value for \(landscape)/\(portrait)")
                continue
            }
            #expect(abs(l * p - 1.0) < eps)
        }
    }

    @Test("Every aspect ratio case has a non-empty label and stable id")
    func aspectRatioLabels() {
        for ratio in CropAspectRatio.allCases {
            #expect(!ratio.label.isEmpty)
            #expect(ratio.id == ratio.rawValue)
        }
    }
}
