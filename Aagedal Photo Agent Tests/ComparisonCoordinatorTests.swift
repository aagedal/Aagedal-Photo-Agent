import CoreGraphics
import CoreImage
import Foundation
import Metal
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Comparison coordinator")
struct ComparisonCoordinatorTests {
    @Test("Clean Feed comparison layouts cover the output without overlapping")
    func cleanFeedComparisonLayoutGeometry() throws {
        let size = CGSize(width: 1_921, height: 1_081)

        let sideBySide = CleanFeedComparisonGeometry.paneRects(
            layout: .sideBySide,
            focusedPane: .right,
            drawableSize: size
        )
        #expect(sideBySide.map(\.0) == [.left, .right])
        #expect(sideBySide[0].1 == CGRect(x: 0, y: 0, width: 959, height: 1_081))
        #expect(sideBySide[1].1 == CGRect(x: 961, y: 0, width: 960, height: 1_081))

        let stacked = CleanFeedComparisonGeometry.paneRects(
            layout: .stacked,
            focusedPane: .left,
            drawableSize: size
        )
        #expect(stacked.map(\.0) == [.left, .right])
        #expect(stacked[0].1 == CGRect(x: 0, y: 0, width: 1_921, height: 539))
        #expect(stacked[1].1 == CGRect(x: 0, y: 541, width: 1_921, height: 540))

        let wipe = CleanFeedComparisonGeometry.paneRects(
            layout: .wipe,
            focusedPane: .right,
            drawableSize: size
        )
        #expect(wipe.map(\.0) == [.left, .right])
        #expect(wipe.allSatisfy { $0.1 == CGRect(origin: .zero, size: size) })
    }

    @Test("wipe geometry supports position and angle changes")
    func comparisonWipeGeometry() throws {
        let rect = CGRect(x: 0, y: 0, width: 1_000, height: 600)
        let vertical = ComparisonWipeGeometry.maskPolygon(
            in: rect,
            position: 0.25,
            angleDegrees: 0
        )
        #expect(vertical.contains(CGPoint(x: 250, y: 0)))
        #expect(vertical.contains(CGPoint(x: 250, y: 600)))
        #expect(!vertical.contains(CGPoint(x: 1_000, y: 300)))

        let segment = try #require(ComparisonWipeGeometry.dividerSegment(
            in: rect,
            position: 0.5,
            angleDegrees: 45
        ))
        #expect(segment.0 != segment.1)

        let position = ComparisonWipeGeometry.position(
            for: CGPoint(x: 750, y: 300),
            in: rect,
            angleDegrees: 0
        )
        #expect(abs(position - 0.75) < 0.000_001)
    }

    @Test("Develop comparison prefers the previous supported filmstrip image")
    func developComparisonPrefersPreviousImage() {
        let previous = imageFile("previous.jpg")
        let current = imageFile("current.jpg")
        let next = imageFile("next.jpg")

        let target = DevelopComparisonSelectionResolver.target(
            in: [previous, current, next],
            currentURL: current.url
        )

        #expect(target?.url == previous.url)
    }

    @Test("Develop comparison falls forward at the filmstrip boundary")
    func developComparisonFallsForward() {
        let current = imageFile("current.jpg")
        let next = imageFile("next.jpg")

        let target = DevelopComparisonSelectionResolver.target(
            in: [current, next],
            currentURL: current.url
        )

        #expect(target?.url == next.url)
    }

    @Test("comparison rendering has a fixed two-pane output budget")
    func comparisonRenderBudget() {
        #expect(ComparisonRenderPolicy.boundedLongEdge(.infinity) == 4_096)
        #expect(ComparisonRenderPolicy.boundedLongEdge(8_192) == 4_096)
        #expect(ComparisonRenderPolicy.boundedLongEdge(2_560) == 2_560)
        #expect(ComparisonRenderPolicy.boundedLongEdge(0) == 1)
        #expect(ComparisonRenderPolicy.maximumResidentOutputBytes == 256 * 1_024 * 1_024)
    }

    @Test("comparison representation chooses the matching pixel cache")
    func comparisonRepresentationPixelRouting() {
        #expect(!ComparisonRenderPolicy.usesEditedPixels(for: .original))
        #expect(ComparisonRenderPolicy.usesEditedPixels(for: .committedEdit))
        #expect(ComparisonRenderPolicy.usesEditedPixels(for: .liveEdit(renderToken: "live")))
        #expect(ComparisonRenderPolicy.usesEditedPixels(for: .primary(renderToken: "primary")))
        #expect(ComparisonRenderPolicy.usesEditedPixels(for: .namedVersion(
            id: UUID(),
            name: "Alternate",
            renderToken: "named"
        )))
    }

    @Test("one source revision can compare Primary with a named version")
    func comparesTwoRepresentationsOfOneRevision() throws {
        let versionID = UUID()
        let primary = makeSource(
            name: "same-source.jpg",
            representation: .primary(renderToken: "primary-token")
        )
        var named = primary
        named.representation = .namedVersion(
            id: versionID,
            name: "Warm editorial",
            renderToken: "named-token"
        )

        let coordinator = try ComparisonCoordinator(session: ComparisonSession(
            origin: .develop,
            left: primary,
            right: named
        ))

        #expect(coordinator.session.hasBothSources)
        #expect(coordinator.session.left.source?.revision == coordinator.session.right.source?.revision)
        #expect(coordinator.session.left.source?.representationLabel == "Primary (XMP)")
        #expect(coordinator.session.right.source?.representationLabel == "Warm editorial")
        #expect(DevelopVersionComparisonTarget.primary != .named(versionID))
    }

    @Test("RAW comparison sources use the serialized decode path")
    func rawComparisonDecodeRouting() {
        for extensionName in ["arw", "cr2", "cr3", "dng", "nef", "raf", "rw2"] {
            #expect(ComparisonRenderPolicy.requiresSerializedDecode(
                for: URL(fileURLWithPath: "/tmp/photo.\(extensionName)")
            ))
        }
        for extensionName in ["jpg", "heic", "png", "tiff"] {
            #expect(!ComparisonRenderPolicy.requiresSerializedDecode(
                for: URL(fileURLWithPath: "/tmp/photo.\(extensionName)")
            ))
        }
    }

    @Test("a cancelled RAW comparison waiter never receives a decode permit")
    func canceledComparisonDecodeWaiter() async {
        let gate = ComparisonDecodeGate(limit: 1)
        let firstPermit = await gate.acquire()
        #expect(firstPermit)

        let waiter = Task { await gate.acquire() }
        await Task.yield()
        waiter.cancel()
        let cancelledPermit = await waiter.value
        #expect(!cancelledPermit)

        await gate.release()
        let nextPermit = await gate.acquire()
        #expect(nextPermit)
        await gate.release()
    }

    @Test("a pre-cancelled comparison render exits before source access")
    func preCancelledComparisonRender() async {
        let missing = ImageFile(
            url: URL(fileURLWithPath: "/tmp/missing-comparison-\(UUID().uuidString).dng")
        )
        let task = Task { () throws -> ComparisonRenderedSource in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ComparisonRenderService().render(
                imageFile: missing,
                settings: nil,
                cache: FullScreenImageCache(),
                maxPixelSize: 8_192
            )
        }

        do {
            _ = try await task.value
            Issue.record("A pre-cancelled comparison render unexpectedly completed")
        } catch is CancellationError {
            // Expected: cancellation wins before revision capture or decode.
        } catch {
            Issue.record("Expected CancellationError, received \(error)")
        }
    }

    @Test("browser selection resolves in visible order")
    func resolvesBrowserSelectionInVisibleOrder() throws {
        let directory = URL(fileURLWithPath: "/tmp/comparison-selection", isDirectory: true)
        let first = ImageFile(url: directory.appendingPathComponent("01.jpg"))
        let second = ImageFile(url: directory.appendingPathComponent("02.jpg"))
        let third = ImageFile(url: directory.appendingPathComponent("03.jpg"))

        let result = try #require(ComparisonSelectionResolver.images(
            in: [third, first, second],
            selectedURLs: [first.url, third.url]
        ))

        #expect(result.map(\.url) == [third.url, first.url])
    }

    @Test("browser comparison requires exactly two supported visible images")
    func rejectsInvalidBrowserSelection() {
        let directory = URL(fileURLWithPath: "/tmp/comparison-selection", isDirectory: true)
        let first = ImageFile(url: directory.appendingPathComponent("01.jpg"))
        let second = ImageFile(url: directory.appendingPathComponent("02.jpg"))
        let unsupported = ImageFile(url: directory.appendingPathComponent("notes.txt"))

        #expect(ComparisonSelectionResolver.images(
            in: [first],
            selectedURLs: [first.url]
        ) == nil)
        #expect(ComparisonSelectionResolver.images(
            in: [first, second, unsupported],
            selectedURLs: [first.url, unsupported.url]
        ) == nil)
        #expect(ComparisonSelectionResolver.images(
            in: [first, second],
            selectedURLs: [first.url, second.url, unsupported.url]
        ) == nil)
    }

    @Test("full-screen comparison keeps the current image and prefers another selection")
    func resolvesFullScreenSelectedPeer() throws {
        let current = imageFile("current.jpg")
        let neighbor = imageFile("neighbor.jpg")
        let selectedPeer = imageFile("selected.jpg")

        let result = try #require(FullScreenComparisonSelectionResolver.images(
            in: [current, neighbor, selectedPeer],
            currentURL: current.url,
            selectedURLs: [current.url, selectedPeer.url]
        ))

        #expect(result.map(\.url) == [current.url, selectedPeer.url])
    }

    @Test("full-screen comparison chooses the next supported neighbor")
    func resolvesFullScreenNextNeighbor() throws {
        let current = imageFile("current.jpg")
        let unsupported = imageFile("notes.txt")
        let next = imageFile("next.jpg")

        let result = try #require(FullScreenComparisonSelectionResolver.images(
            in: [current, unsupported, next],
            currentURL: current.url,
            selectedURLs: [current.url]
        ))

        #expect(result.map(\.url) == [current.url, next.url])
    }

    @Test("full-screen comparison falls back to the previous image at the boundary")
    func resolvesFullScreenPreviousNeighbor() throws {
        let previous = imageFile("previous.jpg")
        let current = imageFile("current.jpg")

        let result = try #require(FullScreenComparisonSelectionResolver.images(
            in: [previous, current],
            currentURL: current.url,
            selectedURLs: [current.url]
        ))

        #expect(result.map(\.url) == [current.url, previous.url])
        #expect(FullScreenComparisonSelectionResolver.images(
            in: [current],
            currentURL: current.url,
            selectedURLs: [current.url]
        ) == nil)
    }

    @Test("filmstrip replacement follows visible order and skips the other pane")
    func resolvesFilmstripReplacement() throws {
        let directory = URL(fileURLWithPath: "/tmp/comparison-navigation", isDirectory: true)
        let images = (1...4).map {
            ImageFile(url: directory.appendingPathComponent("0\($0).jpg"))
        }

        let next = try #require(ComparisonNavigationResolver.replacement(
            in: images,
            currentURL: images[0].url,
            excluding: images[1].url,
            direction: .next
        ))
        #expect(next.url == images[2].url)

        let previous = try #require(ComparisonNavigationResolver.replacement(
            in: images,
            currentURL: images[3].url,
            excluding: images[2].url,
            direction: .previous
        ))
        #expect(previous.url == images[1].url)
        #expect(ComparisonNavigationResolver.replacement(
            in: images,
            currentURL: images[0].url,
            excluding: nil,
            direction: .previous
        ) == nil)
    }

    @Test("missing source offers the nearest distinct survivor")
    func resolvesMissingSourceReplacement() throws {
        let directory = URL(fileURLWithPath: "/tmp/comparison-navigation", isDirectory: true)
        let images = (1...4).map {
            ImageFile(url: directory.appendingPathComponent("0\($0).jpg"))
        }
        let previousOrder = images.map(\.url)
        let available = [images[0], images[2], images[3]]

        let replacement = try #require(ComparisonNavigationResolver.closestReplacement(
            in: available,
            previousOrder: previousOrder,
            missingURL: images[1].url,
            excluding: images[2].url
        ))
        #expect(replacement.url == images[0].url)
    }

    @Test("presentation mutations keep the revision-bound session")
    func updatesPresentationState() throws {
        var coordinator = try makeCoordinator(focusedPane: .left)
        let sessionID = coordinator.session.id

        coordinator.setLayout(.stacked)
        coordinator.setFocusedPane(.right)

        #expect(coordinator.session.id == sessionID)
        #expect(coordinator.session.layout == .stacked)
        #expect(coordinator.session.focusedPane == .right)
        #expect(coordinator.session.hasBothSources)
    }

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

    @Test("rename cycles preserve comparison sources and interaction state")
    func renameCycleReassociation() throws {
        let left = makeSource(name: "left.jpg")
        let right = makeSource(name: "right.jpg")
        var session = ComparisonSession(
            origin: .browser,
            left: left,
            right: right,
            layout: .wipe,
            focusedPane: .right,
            lockState: .unlocked,
            alignment: ComparisonAlignment(
                normalizedCenterOffset: CGPoint(x: 0.1, y: -0.2),
                rightToLeftScaleRatio: 1.5
            ),
            wipePosition: 0.7,
            wipeAngleDegrees: 12
        )
        session.left.viewport.normalizedCenter = CGPoint(x: 0.25, y: 0.35)
        session.right.viewport.normalizedCenter = CGPoint(x: 0.6, y: 0.7)
        let originalID = session.id
        let originalLeftHash = left.revision.sha256
        let originalRightHash = right.revision.sha256

        session.reassociateSources(using: [
            .init(sourceURL: left.revision.canonicalURL, destinationURL: right.revision.canonicalURL),
            .init(sourceURL: right.revision.canonicalURL, destinationURL: left.revision.canonicalURL),
        ])

        #expect(session.id == originalID)
        #expect(session.left.source?.revision.canonicalURL == right.revision.canonicalURL)
        #expect(session.right.source?.revision.canonicalURL == left.revision.canonicalURL)
        #expect(session.left.source?.revision.sha256 == originalLeftHash)
        #expect(session.right.source?.revision.sha256 == originalRightHash)
        #expect(session.layout == .wipe)
        #expect(session.focusedPane == .right)
        #expect(session.lockState == .unlocked)
        #expect(session.alignment.normalizedCenterOffset == CGPoint(x: 0.1, y: -0.2))
        #expect(session.alignment.rightToLeftScaleRatio == 1.5)
        #expect(session.wipePosition == 0.7)
        #expect(session.wipeAngleDegrees == 12)
        #expect(session.left.viewport.normalizedCenter == CGPoint(x: 0.25, y: 0.35))
        #expect(session.right.viewport.normalizedCenter == CGPoint(x: 0.6, y: 0.7))
    }

    @Test("workspace reconciliation applies rename before a stale availability observation")
    func atomicWorkspaceRenameReconciliation() throws {
        let left = makeSource(name: "left.jpg")
        let right = makeSource(name: "right.jpg")
        let renamedLeft = URL(fileURLWithPath: "/tmp/renamed-left.jpg")
        let renamedRight = URL(fileURLWithPath: "/tmp/renamed-right.jpg")
        let mappings: [BatchRenameExecutionPresentation.Mapping] = [
            .init(sourceURL: left.revision.canonicalURL, destinationURL: renamedLeft),
            .init(sourceURL: right.revision.canonicalURL, destinationURL: renamedRight),
        ]
        let coordinator = try ComparisonCoordinator(session: ComparisonSession(
            origin: .browser,
            left: left,
            right: right,
            layout: .wipe,
            focusedPane: .right,
            viewport: ViewportState(
                mode: .actualPixels,
                normalizedCenter: CGPoint(x: 0.3, y: 0.7)
            )
        ))

        // SwiftUI can publish the rename event one render before Browser's replacement images.
        // The destinations are provisionally available for that atomic reconciliation pass.
        let eventFirst = ComparisonWorkspaceSourceReconciler.reconcile(
            coordinator: coordinator,
            previousAvailableOrder: [left.revision.canonicalURL, right.revision.canonicalURL],
            availableImages: [
                ImageFile(url: left.revision.canonicalURL),
                ImageFile(url: right.revision.canonicalURL),
            ],
            renameMappings: mappings
        )
        #expect(eventFirst.missingPanes.isEmpty)
        #expect(eventFirst.coordinator.session.left.source?.revision.canonicalURL == renamedLeft)
        #expect(eventFirst.coordinator.session.right.source?.revision.canonicalURL == renamedRight)

        let availabilitySecond = ComparisonWorkspaceSourceReconciler.reconcile(
            coordinator: eventFirst.coordinator,
            previousAvailableOrder: eventFirst.previousAvailableOrder,
            availableImages: [ImageFile(url: renamedLeft), ImageFile(url: renamedRight)],
            renameMappings: []
        )
        #expect(availabilitySecond.missingPanes.isEmpty)
        #expect(availabilitySecond.coordinator.session.layout == .wipe)
        #expect(availabilitySecond.coordinator.session.focusedPane == .right)
        #expect(
            availabilitySecond.coordinator.session.left.viewport.normalizedCenter
                == CGPoint(x: 0.3, y: 0.7)
        )
    }

    @Test("workspace rename lookup resolves a symlinked folder like source revisions do")
    func symlinkedFolderRenameReconciliation() async throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "apa-comparison-rename-symlink-\(UUID().uuidString)",
            isDirectory: true
        )
        let realFolder = container.appendingPathComponent("real", isDirectory: true)
        let linkedFolder = container.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: realFolder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedFolder, withDestinationURL: realFolder)
        defer { try? FileManager.default.removeItem(at: container) }

        let linkedLeft = linkedFolder.appendingPathComponent("left.jpg")
        let linkedRight = linkedFolder.appendingPathComponent("right.jpg")
        try Data("left".utf8).write(to: linkedLeft)
        try Data("right".utf8).write(to: linkedRight)
        let leftRevision = try await SourceImageRevision.capture(at: linkedLeft)
        let rightRevision = try await SourceImageRevision.capture(at: linkedRight)
        let analysisRepository = AnalysisCaseRepository(sourceFolderURL: linkedFolder)
        let analysisCase = AnalysisCase.create(for: leftRevision)
        try await analysisRepository.save(analysisCase)
        let left = ComparisonSource(revision: leftRevision, representation: .original)
        let right = ComparisonSource(revision: rightRevision, representation: .original)
        let coordinator = try ComparisonCoordinator(session: ComparisonSession(
            origin: .browser,
            left: left,
            right: right
        ))

        let linkedRenamed = linkedFolder.appendingPathComponent("renamed.jpg")
        try FileManager.default.moveItem(at: linkedLeft, to: linkedRenamed)
        let mappings: [BatchRenameExecutionPresentation.Mapping] = [
            .init(sourceURL: linkedLeft, destinationURL: linkedRenamed),
        ]
        let persistentResult = await RenameReassociationService().reassociate(
            folderURL: linkedFolder,
            mappings: mappings
        )
        #expect(persistentResult.succeeded)
        #expect(persistentResult.analysisCaseCount == 1)

        let result = ComparisonWorkspaceSourceReconciler.reconcile(
            coordinator: coordinator,
            previousAvailableOrder: [linkedLeft, linkedRight],
            availableImages: [ImageFile(url: linkedRenamed), ImageFile(url: linkedRight)],
            renameMappings: mappings
        )

        #expect(result.missingPanes.isEmpty)
        #expect(
            result.coordinator.session.left.source?.revision.canonicalURL
                == realFolder.appendingPathComponent("renamed.jpg").standardizedFileURL
        )
        #expect(result.coordinator.session.left.source?.revision.sha256 == leftRevision.sha256)

        let renamedRevision = try await SourceImageRevision.capture(at: linkedRenamed)
        guard case .exact(let reopenedCase) = await analysisRepository.loadMostRelevantCase(
            for: renamedRevision
        ) else {
            Issue.record("Expected the analysis case to reopen after a symlinked-folder rename")
            return
        }
        #expect(reopenedCase.id == analysisCase.id)
        #expect(
            reopenedCase.source.canonicalURL
                == realFolder.appendingPathComponent("renamed.jpg").standardizedFileURL
        )
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

    private func imageFile(_ filename: String) -> ImageFile {
        ImageFile(url: URL(fileURLWithPath: "/tmp/develop-comparison/\(filename)"))
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

/// Repeatable host-side stress coverage for the render-state boundary shared by Develop preview,
/// Clean Feed, and export. Keep this suite independently selectable: the TSAN runner intentionally
/// repeats it more heavily than the ordinary test configuration.
@Suite("Metal pipeline TSAN stress", .serialized)
struct MetalPipelineTSANStressTests {
    @Test("preview, Clean Feed, export cancellation, and navigation overlap")
    @MainActor
    func combinedRenderLifecycleStress() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let previewQueue = device.makeCommandQueue(),
              let cleanFeedQueue = device.makeCommandQueue(),
              let preview = MetalLivePreviewPipeline(device: device, commandQueue: previewQueue),
              let cleanFeed = MetalLivePreviewPipeline(device: device, commandQueue: cleanFeedQueue) else {
            Issue.record("The Metal TSAN stress scenario requires a system Metal device and edit shader")
            return
        }

        let iterationCount = 8
        let cleanFeedUpdates = MetalStressCounter()
        cleanFeed.onParamsChanged = { cleanFeedUpdates.increment() }
        preview.mirror = cleanFeed
        #expect(preview.mirror === cleanFeed)
        defer {
            preview.mirror = nil
            cleanFeed.onParamsChanged = nil
        }

        let initialImage = Self.makeImage(width: 192, height: 128, seed: 0)
        preview.beginSourceImageSession(1)
        #expect(preview.uploadSourceImage(initialImage, sessionGeneration: 1))
        preview.updateParams(Self.makeSettings(iteration: 0))
        #expect(preview.hasSourceTexture)
        #expect(cleanFeed.hasSourceTexture)
        #expect(preview.sourceTextureSize == cleanFeed.sourceTextureSize)

        // Exercise the real editor/mirror publication boundary, not only its pure lock gate.
        // Replacing the image clears both textures and an obsolete completed upload cannot restore
        // either one; only the new generation may republish the shared source.
        preview.beginSourceImageSession(2)
        #expect(!preview.hasSourceTexture)
        #expect(!cleanFeed.hasSourceTexture)
        #expect(!preview.uploadSourceImage(initialImage, sessionGeneration: 1))
        #expect(!preview.hasSourceTexture)
        #expect(!cleanFeed.hasSourceTexture)
        #expect(preview.uploadSourceImage(initialImage, sessionGeneration: 2))
        #expect(preview.hasSourceTexture)
        #expect(cleanFeed.hasSourceTexture)

        for iteration in 0..<iterationCount {
            // Start real export work on the shared serialized offscreen renderer. Constructing
            // inputs inside each detached task avoids sharing mutable Core Image filter graphs.
            let exports = (0..<2).map { exportIndex in
                Task.detached {
                    let seed = iteration * 10 + exportIndex + 1
                    return await MetalEditPipeline.renderOffscreenAsync(
                        source: Self.makeImage(width: 384, height: 256, seed: seed),
                        settings: Self.makeSettings(iteration: seed)
                    )
                }
            }

            // Model navigation's adjacent-image precache: upload on a worker, then promote the
            // completed texture on the main-thread live-preview owner below.
            let navigationURL = URL(fileURLWithPath: "/tmp/metal-tsan-navigation-\(iteration).tiff")
            let navigationSize = CGSize(
                width: 176 + (iteration % 5) * 8,
                height: 120 + (iteration % 3) * 8
            )
            let navigation = Task.detached {
                preview.precacheTexture(
                    for: navigationURL,
                    ciImage: Self.makeImage(
                        width: Int(navigationSize.width),
                        height: Int(navigationSize.height),
                        seed: iteration + 100
                    )
                )
            }

            // Hold a render request until it is definitely cancelled, then release it into the
            // production async entry. This deterministically exercises its cancellation fast path
            // while sibling exports are already contending for the same serial renderer.
            let cancellationGate = MetalStressGate()
            let cancelledExport = Task.detached {
                await cancellationGate.wait()
                return await MetalEditPipeline.renderOffscreenAsync(
                    source: Self.makeImage(width: 512, height: 320, seed: iteration + 200),
                    settings: Self.makeSettings(iteration: iteration + 200)
                )
            }
            await Task.yield()
            cancelledExport.cancel()
            await cancellationGate.open()

            // Slider/viewport activity is main-thread-owned and mirrors each update into the
            // dedicated Clean Feed pipeline while exports and navigation uploads run off-thread.
            preview.updateParams(Self.makeSettings(iteration: iteration + 1))
            preview.updateViewport(
                zoomScale: 1 + CGFloat(iteration % 4) * 0.25,
                offset: CGSize(
                    width: CGFloat((iteration % 3) - 1) * 6,
                    height: CGFloat((iteration % 5) - 2) * 4
                ),
                containerSize: CGSize(width: 640, height: 360),
                imageSize: preview.sourceTextureSize ?? CGSize(width: 192, height: 128)
            )

            await navigation.value
            let promotedWhiteBalance = preview.applyCachedTexture(for: navigationURL)
            #expect(promotedWhiteBalance != nil)
            #expect(preview.sourceTextureSize == navigationSize)
            #expect(cleanFeed.sourceTextureSize == navigationSize)

            for export in exports {
                let result = await export.value
                #expect(result != nil)
                #expect((result?.extent.width ?? 0) > 0)
                #expect((result?.extent.height ?? 0) > 0)
            }
            #expect(await cancelledExport.value == nil)
        }

        #expect(cleanFeedUpdates.value >= iterationCount + 1)
    }

    private nonisolated static func makeSettings(iteration: Int) -> CameraRawSettings {
        var settings = CameraRawSettings()
        settings.exposure2012 = Double((iteration % 9) - 4) * 0.08
        settings.contrast2012 = (iteration % 31) - 15
        settings.saturation = (iteration % 21) - 10
        settings.vibrance = (iteration % 17) - 8
        settings.hasSettings = true
        return settings
    }

    private nonisolated static func makeImage(width: Int, height: Int, seed: Int) -> CIImage {
        let red = CGFloat((seed * 37) % 255) / 255
        let green = CGFloat((seed * 67 + 31) % 255) / 255
        let blue = CGFloat((seed * 97 + 73) % 255) / 255
        return CIImage(color: CIColor(red: red, green: green, blue: blue, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }
}

private actor MetalStressGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        pending.forEach { $0.resume() }
    }
}

private nonisolated final class MetalStressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}
