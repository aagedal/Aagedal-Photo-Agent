import CoreGraphics
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Comparison session")
struct ComparisonSessionTests {
    @Test("representations expose explicit badges and a missing source remains replaceable")
    func sourceRepresentationsAndReplacement() {
        let original = ComparisonSource(
            revision: revision(named: "left.jpg", hash: "left"),
            representation: .original
        )
        var session = ComparisonSession(
            origin: .browser,
            leftSource: original,
            rightSource: ComparisonSource(
                revision: revision(named: "right.jpg", hash: "right"),
                representation: .liveEdit(renderToken: "render-1")
            )
        )

        #expect(session.leftSource.representation.label == "Original")
        #expect(session.rightSource.representation.label == "Live Edit")

        session.markSourceMissing(in: .right)
        #expect(session.rightSource.availability == .missing)
        #expect(session.leftSource.availability == .available)

        let replacement = ComparisonSource(
            revision: revision(named: "replacement.jpg", hash: "replacement"),
            representation: .namedVersion(id: UUID(), name: "  Selects  ")
        )
        session.replaceSource(replacement, in: .right)
        #expect(session.rightSource.id == replacement.id)
        #expect(session.rightSource.representation.label == "Selects")
        #expect(session.rightSource.availability == .available)
    }

    @Test("Browser comparison requires exactly two supported images in visible order")
    func browserSelectionResolution() {
        let first = ImageFile(url: URL(fileURLWithPath: "/tmp/first.jpg"))
        let second = ImageFile(url: URL(fileURLWithPath: "/tmp/second.raw"))
        let unsupported = ImageFile(url: URL(fileURLWithPath: "/tmp/notes.txt"))

        let pair = ComparisonSelectionResolver.images(
            in: [second, first, unsupported],
            selectedURLs: [first.url, second.url]
        )
        #expect(pair?.left.url == second.url)
        #expect(pair?.right.url == first.url)

        #expect(ComparisonSelectionResolver.images(
            in: [first, unsupported],
            selectedURLs: [first.url, unsupported.url]
        ) == nil)
        #expect(ComparisonSelectionResolver.images(
            in: [first, second],
            selectedURLs: [first.url]
        ) == nil)
    }

    @Test("locked changes copy normalized center, pixel scale, and interpolation")
    func lockedSynchronization() throws {
        var session = makeSession()
        var coordinator = ComparisonCoordinator()
        let requested = ViewportState(
            mode: .custom(imagePixelsPerBackingPixel: 0.5),
            normalizedCenter: CGPoint(x: 0.3, y: 0.4),
            interpolation: .nearest
        )

        let transaction = try #require(coordinator.updateViewport(
            requested,
            in: .left,
            session: &session,
            surfaces: regularSurfaces
        ))

        #expect(transaction.changedPanes == [.left, .right])
        #expect(transaction.exactLockWasPossible)
        #expect(session.leftViewport == requested)
        #expect(session.rightViewport == requested)
    }

    @Test("each pane clamps independently and reports an inexact lock")
    func independentClamping() throws {
        var session = makeSession()
        var coordinator = ComparisonCoordinator()
        let surfaces = ComparisonViewportSurfaces(
            left: ComparisonViewportSurface(
                displayedPixelSize: CGSize(width: 1_000, height: 200),
                viewSize: CGSize(width: 300, height: 300),
                backingScale: 1
            ),
            right: ComparisonViewportSurface(
                displayedPixelSize: CGSize(width: 200, height: 1_000),
                viewSize: CGSize(width: 300, height: 300),
                backingScale: 1
            )
        )

        let transaction = try #require(coordinator.updateViewport(
            ViewportState(
                mode: .actualPixels,
                normalizedCenter: CGPoint(x: 0.1, y: 0.9)
            ),
            in: .left,
            session: &session,
            surfaces: surfaces
        ))

        expectEqual(session.leftViewport.normalizedCenter, CGPoint(x: 0.15, y: 0.5))
        expectEqual(session.rightViewport.normalizedCenter, CGPoint(x: 0.5, y: 0.5))
        #expect(transaction.clampedPanes == [.left, .right])
        #expect(!transaction.exactLockWasPossible)
    }

    @Test("saved alignment survives temporary unlock and reset clears it")
    func alignmentLifecycle() throws {
        var session = makeSession(
            leftViewport: ViewportState(
                mode: .custom(imagePixelsPerBackingPixel: 0.5),
                normalizedCenter: CGPoint(x: 0.3, y: 0.4)
            ),
            rightViewport: ViewportState(
                mode: .custom(imagePixelsPerBackingPixel: 0.75),
                normalizedCenter: CGPoint(x: 0.4, y: 0.2)
            )
        )
        var coordinator = ComparisonCoordinator()

        coordinator.beginAlignment(anchor: .left, session: &session)
        try coordinator.saveAlignment(session: &session, surfaces: regularSurfaces)
        #expect(session.lockState == .lockedWithOffset)
        expectEqual(session.alignment.normalizedCenterOffset, CGSize(width: 0.1, height: -0.2))
        expectEqual(session.alignment.scaleRatio, 1.5)

        coordinator.temporarilyUnlock(session: &session)
        let savedAlignment = session.alignment
        let rightBeforeUnlockedPan = session.rightViewport
        _ = try coordinator.updateViewport(
            ViewportState(
                mode: .custom(imagePixelsPerBackingPixel: 0.5),
                normalizedCenter: CGPoint(x: 0.6, y: 0.6)
            ),
            in: .left,
            session: &session,
            surfaces: regularSurfaces
        )
        #expect(session.rightViewport == rightBeforeUnlockedPan)
        #expect(session.alignment == savedAlignment)

        coordinator.relock(session: &session)
        _ = try coordinator.updateViewport(
            ViewportState(
                mode: .custom(imagePixelsPerBackingPixel: 0.5),
                normalizedCenter: CGPoint(x: 0.5, y: 0.5)
            ),
            in: .left,
            session: &session,
            surfaces: regularSurfaces
        )
        expectEqual(session.rightViewport.normalizedCenter, CGPoint(x: 0.6, y: 0.3))
        #expect(session.rightViewport.mode == .custom(imagePixelsPerBackingPixel: 0.75))

        _ = try coordinator.resetAlignment(
            anchoredAt: .left,
            session: &session,
            surfaces: regularSurfaces
        )
        #expect(session.lockState == .locked)
        #expect(session.alignment == .identity)
        expectEqual(session.rightViewport.normalizedCenter, session.leftViewport.normalizedCenter)
        #expect(session.rightViewport.mode == session.leftViewport.mode)
    }

    @Test("out-of-order transaction echoes are ignored without blocking later user changes")
    func feedbackSuppression() throws {
        var session = makeSession(
            leftViewport: ViewportState(mode: .actualPixels),
            rightViewport: ViewportState(mode: .actualPixels)
        )
        var coordinator = ComparisonCoordinator()

        let first = try #require(coordinator.updateViewport(
            ViewportState(
                mode: .actualPixels,
                normalizedCenter: CGPoint(x: 0.25, y: 0.25)
            ),
            in: .left,
            session: &session,
            surfaces: regularSurfaces
        ))
        let second = try #require(coordinator.updateViewport(
            ViewportState(
                mode: .actualPixels,
                normalizedCenter: CGPoint(x: 0.4, y: 0.45)
            ),
            in: .left,
            session: &session,
            surfaces: regularSurfaces
        ))
        let olderEcho = try coordinator.updateViewport(
            first.rightViewport,
            in: .right,
            session: &session,
            surfaces: regularSurfaces,
            causedBy: first.id
        )
        #expect(olderEcho == nil)
        let newerEcho = try coordinator.updateViewport(
            second.rightViewport,
            in: .right,
            session: &session,
            surfaces: regularSurfaces,
            causedBy: second.id
        )
        #expect(newerEcho == nil)
        expectEqual(session.rightViewport.normalizedCenter, CGPoint(x: 0.4, y: 0.45))

        let userChange = try #require(coordinator.updateViewport(
            ViewportState(
                mode: .actualPixels,
                normalizedCenter: CGPoint(x: 0.7, y: 0.65)
            ),
            in: .right,
            session: &session,
            surfaces: regularSurfaces
        ))
        #expect(userChange.id != first.id)
        #expect(userChange.id != second.id)
        expectEqual(session.leftViewport.normalizedCenter, CGPoint(x: 0.7, y: 0.65))
    }

    private var regularSurfaces: ComparisonViewportSurfaces {
        ComparisonViewportSurfaces(
            left: ComparisonViewportSurface(
                displayedPixelSize: CGSize(width: 1_000, height: 1_000),
                viewSize: CGSize(width: 200, height: 200),
                backingScale: 1
            ),
            right: ComparisonViewportSurface(
                displayedPixelSize: CGSize(width: 800, height: 1_200),
                viewSize: CGSize(width: 200, height: 200),
                backingScale: 1
            )
        )
    }

    private func makeSession(
        leftViewport: ViewportState = ViewportState(),
        rightViewport: ViewportState = ViewportState()
    ) -> ComparisonSession {
        ComparisonSession(
            origin: .browser,
            leftSource: ComparisonSource(
                revision: revision(named: "left.jpg", hash: "left"),
                representation: .committedEdit
            ),
            rightSource: ComparisonSource(
                revision: revision(named: "right.jpg", hash: "right"),
                representation: .committedEdit
            ),
            leftViewport: leftViewport,
            rightViewport: rightViewport
        )
    }

    private func revision(named filename: String, hash: String) -> SourceImageRevision {
        SourceImageRevision(
            canonicalURL: URL(fileURLWithPath: "/tmp/\(filename)"),
            fileResourceIdentifier: nil,
            filenameAtCreation: filename,
            byteCount: 100,
            contentModificationDate: Date(timeIntervalSince1970: 1),
            pixelWidth: 1_000,
            pixelHeight: 1_000,
            exifOrientation: 1,
            sha256: hash,
            hashCompletedAt: Date(timeIntervalSince1970: 2)
        )
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

    private func expectEqual(
        _ actual: CGSize,
        _ expected: CGSize,
        accuracy: CGFloat = 0.000_000_1,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            abs(actual.width - expected.width) <= accuracy
                && abs(actual.height - expected.height) <= accuracy,
            sourceLocation: sourceLocation
        )
    }
}
