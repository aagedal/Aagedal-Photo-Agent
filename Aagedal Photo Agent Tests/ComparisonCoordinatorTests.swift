import CoreGraphics
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Comparison coordinator")
struct ComparisonCoordinatorTests {
    @Test("locked panes share normalized center and comparable pixel scale")
    func synchronizesCenterAndScale() throws {
        var coordinator = try makeCoordinator()
        let geometries = makeGeometries(
            leftPixels: CGSize(width: 1_200, height: 800),
            rightPixels: CGSize(width: 800, height: 1_200)
        )
        let requested = ViewportState(
            mode: .custom(imagePixelsPerBackingPixel: 0.75),
            normalizedCenter: CGPoint(x: 0.6, y: 0.4),
            interpolation: .nearest
        )

        let update = try coordinator.updateViewport(
            in: .left,
            to: requested,
            geometries: geometries
        )
        let transaction = try #require(update)

        expectEqual(transaction.leftViewport.normalizedCenter, CGPoint(x: 0.6, y: 0.4))
        expectEqual(transaction.rightViewport.normalizedCenter, CGPoint(x: 0.6, y: 0.4))
        expectCustomScale(transaction.rightViewport, 0.75)
        #expect(transaction.rightViewport.interpolation == .nearest)
        #expect(transaction.exactLockWasPossible)
    }

    @Test("different aspect ratios clamp independently without feedback")
    func clampsFollowerWithoutFeedback() throws {
        var coordinator = try makeCoordinator()
        let geometries = makeGeometries(
            leftPixels: CGSize(width: 1_000, height: 1_000),
            rightPixels: CGSize(width: 100, height: 1_000),
            viewSize: CGSize(width: 200, height: 200)
        )
        let requested = ViewportState(
            mode: .actualPixels,
            normalizedCenter: CGPoint(x: 0.1, y: 0.8)
        )

        let update = try coordinator.updateViewport(
            in: .left,
            to: requested,
            geometries: geometries
        )
        let transaction = try #require(update)

        expectEqual(transaction.leftViewport.normalizedCenter, CGPoint(x: 0.1, y: 0.8))
        // The narrow right image fits horizontally, so only its x center is clamped.
        expectEqual(transaction.rightViewport.normalizedCenter, CGPoint(x: 0.5, y: 0.8))
        #expect(transaction.followerWasClamped)
        #expect(!transaction.exactLockWasPossible)

        // A UI callback tagged with the transaction cannot make the clamped follower a new driver.
        let ignored = try coordinator.updateViewport(
            in: .right,
            to: transaction.rightViewport,
            geometries: geometries,
            causedBy: transaction.id
        )
        #expect(ignored == nil)
        expectEqual(coordinator.session.left.viewport.normalizedCenter, CGPoint(x: 0.1, y: 0.8))
    }

    @Test("alignment offset and scale ratio survive temporary unlock")
    func savesAndPreservesAlignment() throws {
        var coordinator = try makeCoordinator()
        let geometries = makeGeometries()
        coordinator.beginAlignment(anchor: .left)

        let alignedRight = ViewportState(
            mode: .custom(imagePixelsPerBackingPixel: 2),
            normalizedCenter: CGPoint(x: 0.7, y: 0.4)
        )
        _ = try coordinator.updateViewport(in: .right, to: alignedRight, geometries: geometries)
        try coordinator.commitAlignment(geometries: geometries)

        expectEqual(
            coordinator.session.alignment.normalizedCenterOffset,
            CGPoint(x: 0.2, y: -0.1)
        )
        expectEqual(coordinator.session.alignment.rightToLeftScaleRatio, 2)

        coordinator.unlock()
        _ = try coordinator.updateViewport(
            in: .right,
            to: ViewportState(
                mode: .custom(imagePixelsPerBackingPixel: 0.25),
                normalizedCenter: CGPoint(x: 0.2, y: 0.2)
            ),
            geometries: geometries
        )
        #expect(coordinator.session.lockState == .unlocked)
        expectEqual(coordinator.session.alignment.rightToLeftScaleRatio, 2)

        let relockUpdate = try coordinator.relock(drivenBy: .left, geometries: geometries)
        let relocked = try #require(relockUpdate)
        expectEqual(relocked.rightViewport.normalizedCenter, CGPoint(x: 0.7, y: 0.4))
        expectCustomScale(relocked.rightViewport, 2)
    }

    @Test("reset alignment restores equal center and scale")
    func resetsAlignment() throws {
        let session = ComparisonSession(
            origin: .browser,
            left: makeSource(name: "left.jpg"),
            right: makeSource(name: "right.jpg"),
            alignment: ComparisonAlignment(
                normalizedCenterOffset: CGPoint(x: 0.1, y: -0.2),
                rightToLeftScaleRatio: 1.5
            ),
            viewport: ViewportState(
                mode: .custom(imagePixelsPerBackingPixel: 0.5),
                normalizedCenter: CGPoint(x: 0.4, y: 0.6)
            )
        )
        var coordinator = try ComparisonCoordinator(session: session)

        let resetUpdate = try coordinator.resetAlignment(
            drivenBy: .left,
            geometries: makeGeometries()
        )
        let transaction = try #require(resetUpdate)

        #expect(coordinator.session.alignment == .identity)
        expectEqual(transaction.rightViewport.normalizedCenter, CGPoint(x: 0.4, y: 0.6))
        expectCustomScale(transaction.rightViewport, 0.5)
    }

    @Test("missing source keeps the survivor and moves focus")
    func missingSourcePreservesSession() throws {
        var coordinator = try makeCoordinator(focusedPane: .right)
        let survivor = try #require(coordinator.session.left.source)

        coordinator.markSourceMissing(in: .right)

        #expect(coordinator.session.left.source == survivor)
        #expect(coordinator.session.right.source == nil)
        #expect(coordinator.session.focusedPane == .left)
        #expect(!coordinator.session.hasBothSources)

        let replacement = makeSource(name: "replacement.jpg", representation: .original)
        coordinator.replaceSource(replacement, in: .right)
        #expect(coordinator.session.right.source == replacement)
        #expect(coordinator.session.hasBothSources)
    }

    @Test("representation labels and HDR mismatch are explicit")
    func sourceLabelsAndDynamicRange() {
        let versionID = UUID()
        let left = makeSource(
            name: "left.jpg",
            representation: .namedVersion(
                id: versionID,
                name: "Night grade",
                renderToken: "version-2"
            ),
            dynamicRange: .hdr
        )
        let right = makeSource(
            name: "right.jpg",
            representation: .committedEdit,
            dynamicRange: .sdr
        )
        let session = ComparisonSession(origin: .develop, left: left, right: right)

        #expect(session.left.source?.representationLabel == "Night grade")
        #expect(session.left.source?.representation.renderToken == "version-2")
        #expect(session.right.source?.representationLabel == "Committed Edit")
        #expect(session.hasDynamicRangeMismatch)
    }

    @Test("invalid alignment is rejected")
    func rejectsInvalidAlignment() {
        let session = ComparisonSession(
            origin: .browser,
            left: makeSource(name: "left.jpg"),
            right: makeSource(name: "right.jpg"),
            alignment: ComparisonAlignment(
                normalizedCenterOffset: .zero,
                rightToLeftScaleRatio: 0
            )
        )

        #expect(throws: ComparisonCoordinatorError.invalidAlignmentScaleRatio(0)) {
            try ComparisonCoordinator(session: session)
        }
    }

    @Test("failed synchronization leaves the session unchanged")
    func updateIsAtomicOnFailure() throws {
        var coordinator = try makeCoordinator()
        let original = coordinator.session
        let onlyLeftGeometry: [ComparisonPane: ComparisonPaneGeometry] = [
            .left: ComparisonPaneGeometry(
                displayedPixelSize: CGSize(width: 1_000, height: 1_000),
                viewSize: CGSize(width: 200, height: 200),
                backingScale: 1
            )
        ]

        do {
            _ = try coordinator.updateViewport(
                in: .left,
                to: ViewportState(
                    mode: .actualPixels,
                    normalizedCenter: CGPoint(x: 0.2, y: 0.8)
                ),
                geometries: onlyLeftGeometry
            )
            Issue.record("Expected missing follower geometry to fail")
        } catch let error as ComparisonCoordinatorError {
            #expect(error == .missingGeometry(.right))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(coordinator.session == original)
    }

    private func makeCoordinator(
        focusedPane: ComparisonPane = .left
    ) throws -> ComparisonCoordinator {
        try ComparisonCoordinator(
            session: ComparisonSession(
                origin: .browser,
                left: makeSource(name: "left.jpg"),
                right: makeSource(name: "right.jpg"),
                focusedPane: focusedPane,
                viewport: ViewportState(mode: .actualPixels)
            )
        )
    }

    private func makeGeometries(
        leftPixels: CGSize = CGSize(width: 1_000, height: 1_000),
        rightPixels: CGSize = CGSize(width: 1_000, height: 1_000),
        viewSize: CGSize = CGSize(width: 200, height: 200),
        backingScale: CGFloat = 1
    ) -> [ComparisonPane: ComparisonPaneGeometry] {
        [
            .left: ComparisonPaneGeometry(
                displayedPixelSize: leftPixels,
                viewSize: viewSize,
                backingScale: backingScale
            ),
            .right: ComparisonPaneGeometry(
                displayedPixelSize: rightPixels,
                viewSize: viewSize,
                backingScale: backingScale
            )
        ]
    }

    private func makeSource(
        name: String,
        representation: ComparisonRepresentation = .committedEdit,
        dynamicRange: ComparisonDynamicRange = .unknown
    ) -> ComparisonSource {
        ComparisonSource(
            revision: SourceImageRevision(
                canonicalURL: URL(fileURLWithPath: "/tmp/\(name)"),
                fileResourceIdentifier: nil,
                filenameAtCreation: name,
                byteCount: 100,
                contentModificationDate: Date(timeIntervalSince1970: 100),
                pixelWidth: 1_000,
                pixelHeight: 1_000,
                exifOrientation: 1,
                sha256: String(repeating: name == "left.jpg" ? "a" : "b", count: 64),
                hashCompletedAt: Date(timeIntervalSince1970: 101)
            ),
            representation: representation,
            dynamicRange: dynamicRange
        )
    }

    private func expectCustomScale(
        _ viewport: ViewportState,
        _ expected: CGFloat,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard case let .custom(actual) = viewport.mode else {
            Issue.record("Expected custom viewport scale", sourceLocation: sourceLocation)
            return
        }
        expectEqual(actual, expected, sourceLocation: sourceLocation)
    }

    private func expectEqual(
        _ actual: CGFloat,
        _ expected: CGFloat,
        accuracy: CGFloat = 0.000_000_1,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(abs(actual - expected) <= accuracy, sourceLocation: sourceLocation)
    }

    private func expectEqual(
        _ actual: CGPoint,
        _ expected: CGPoint,
        accuracy: CGFloat = 0.000_000_1,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            abs(actual.x - expected.x) <= accuracy
                && abs(actual.y - expected.y) <= accuracy,
            sourceLocation: sourceLocation
        )
    }
}
