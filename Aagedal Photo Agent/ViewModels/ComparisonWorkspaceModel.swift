import AppKit
import Observation

@MainActor
@Observable
final class ComparisonWorkspaceModel {
    enum LoadState: Equatable {
        case idle
        case identifyingSources
        case loadingPreviews
        case ready
        case failed(String)
    }

    struct PaneImage: @unchecked Sendable {
        let cgImage: CGImage
        let isHDR: Bool
    }

    private(set) var session: ComparisonSession?
    private(set) var loadState: LoadState = .idle
    private(set) var paneImages: [ComparisonPane: PaneImage] = [:]
    private(set) var sourceFiles: [ComparisonPane: ImageFile] = [:]
    private(set) var surfaces: [ComparisonPane: ComparisonViewportSurface] = [:]
    private(set) var lastClampedPanes: Set<ComparisonPane> = []

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var coordinator = ComparisonCoordinator()

    deinit {
        loadTask?.cancel()
    }

    func open(left: ImageFile, right: ImageFile) {
        loadTask?.cancel()
        session = nil
        paneImages = [:]
        surfaces = [:]
        lastClampedPanes = []
        sourceFiles = [.left: left, .right: right]
        loadState = .identifyingSources

        loadTask = Task { [weak self] in
            do {
                async let leftRevision = Self.captureRevision(for: left)
                async let rightRevision = Self.captureRevision(for: right)
                let revisions = try await (leftRevision, rightRevision)
                try Task.checkCancellation()

                guard let self,
                      self.sourceFiles[.left]?.url == left.url,
                      self.sourceFiles[.right]?.url == right.url else { return }

                self.session = ComparisonSession(
                    origin: .browser,
                    leftSource: ComparisonSource(
                        revision: revisions.0,
                        representation: Self.representation(for: left)
                    ),
                    rightSource: ComparisonSource(
                        revision: revisions.1,
                        representation: Self.representation(for: right)
                    )
                )
                self.loadState = .loadingPreviews

                async let leftImage = Self.loadPreview(for: left)
                async let rightImage = Self.loadPreview(for: right)
                let images = await (leftImage, rightImage)
                try Task.checkCancellation()

                guard self.sourceFiles[.left]?.url == left.url,
                      self.sourceFiles[.right]?.url == right.url else { return }

                if let leftImage = images.0 {
                    self.paneImages[.left] = leftImage
                }
                if let rightImage = images.1 {
                    self.paneImages[.right] = rightImage
                }

                guard images.0 != nil || images.1 != nil else {
                    self.loadState = .failed("Neither image could be decoded for comparison.")
                    return
                }
                self.loadState = .ready
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.sourceFiles[.left]?.url == left.url,
                      self.sourceFiles[.right]?.url == right.url else { return }
                self.loadState = .failed(
                    error.localizedDescription.isEmpty
                        ? "The comparison sources could not be identified."
                        : error.localizedDescription
                )
            }
        }
    }

    func retry() {
        guard let left = sourceFiles[.left], let right = sourceFiles[.right] else { return }
        open(left: left, right: right)
    }

    func close() {
        loadTask?.cancel()
        loadTask = nil
        session = nil
        paneImages = [:]
        sourceFiles = [:]
        surfaces = [:]
        lastClampedPanes = []
        loadState = .idle
    }

    func setLayout(_ layout: ComparisonLayout) {
        guard var session else { return }
        session.layout = layout
        self.session = session
    }

    func focus(_ pane: ComparisonPane) {
        guard var session else { return }
        session.focusedPane = pane
        self.session = session
    }

    func updateSurface(
        for pane: ComparisonPane,
        viewSize: CGSize,
        backingScale: CGFloat
    ) {
        guard viewSize.width > 0, viewSize.height > 0,
              backingScale > 0,
              let displayedPixelSize = displayedPixelSize(for: pane) else { return }
        surfaces[pane] = ComparisonViewportSurface(
            displayedPixelSize: displayedPixelSize,
            viewSize: viewSize,
            backingScale: backingScale
        )
        reapplyFocusedViewportIfPossible()
    }

    func updateViewport(_ viewport: ViewportState, in pane: ComparisonPane) {
        guard var session else { return }
        guard let surfaces = resolvedSurfaces else {
            session.setViewport(viewport, for: pane)
            self.session = session
            return
        }

        do {
            let transaction = try coordinator.updateViewport(
                viewport,
                in: pane,
                session: &session,
                surfaces: surfaces
            )
            lastClampedPanes = transaction?.clampedPanes ?? []
            self.session = session
        } catch {
            // Surface values are validated before storage. If a transient resize still creates
            // invalid geometry, keep the previous atomic session rather than partially syncing.
        }
    }

    func setViewportMode(_ mode: ViewportState.Mode) {
        guard let session else { return }
        let pane = session.focusedPane
        var viewport = session.viewport(for: pane)
        viewport.mode = mode
        updateViewport(viewport, in: pane)
    }

    func setZoomPercent(_ percent: CGFloat) {
        let clampedPercent = min(max(percent, 12.5), 800)
        setViewportMode(.custom(imagePixelsPerBackingPixel: 100 / clampedPercent))
    }

    func zoomPercent(for pane: ComparisonPane) -> CGFloat? {
        guard let session, let surface = surfaces[pane] else { return nil }
        return try? 100 / session.viewport(for: pane).geometry(
            displayedPixelSize: surface.displayedPixelSize,
            viewSize: surface.viewSize,
            backingScale: surface.backingScale
        ).imagePixelsPerBackingPixel
    }

    func toggleLock() {
        guard var session else { return }
        switch session.lockState {
        case .locked, .lockedWithOffset:
            coordinator.temporarilyUnlock(session: &session)
        case .temporarilyUnlocked:
            coordinator.relock(session: &session)
        case .aligning:
            return
        }
        lastClampedPanes = []
        self.session = session
    }

    func setInterpolation(_ interpolation: ViewportState.Interpolation) {
        guard let session else { return }
        let pane = session.focusedPane
        var viewport = session.viewport(for: pane)
        viewport.interpolation = interpolation
        updateViewport(viewport, in: pane)
    }

    func resetAlignment() {
        guard var session, let surfaces = resolvedSurfaces else { return }
        do {
            let transaction = try coordinator.resetAlignment(
                anchoredAt: session.focusedPane,
                session: &session,
                surfaces: surfaces
            )
            lastClampedPanes = transaction?.clampedPanes ?? []
            self.session = session
        } catch {
            return
        }
    }

    private var resolvedSurfaces: ComparisonViewportSurfaces? {
        guard let left = surfaces[.left], let right = surfaces[.right] else { return nil }
        return ComparisonViewportSurfaces(left: left, right: right)
    }

    private func displayedPixelSize(for pane: ComparisonPane) -> CGSize? {
        if let image = paneImages[pane] {
            return CGSize(width: image.cgImage.width, height: image.cgImage.height)
        }
        guard let revision = session?.source(for: pane).revision,
              let width = revision.pixelWidth,
              let height = revision.pixelHeight,
              width > 0,
              height > 0 else { return nil }
        let orientation = revision.exifOrientation ?? 1
        return orientation >= 5 && orientation <= 8
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
    }

    private func reapplyFocusedViewportIfPossible() {
        guard let session, resolvedSurfaces != nil else { return }
        updateViewport(session.viewport(for: session.focusedPane), in: session.focusedPane)
    }

    private nonisolated static func captureRevision(for image: ImageFile) async throws -> SourceImageRevision {
        let pixelSize = FullScreenImageCache.nativePixelSize(of: image.url)
        return try await SourceImageRevision.capture(
            at: image.url,
            pixelWidth: pixelSize.map { Int($0.width) },
            pixelHeight: pixelSize.map { Int($0.height) },
            exifOrientation: image.exifOrientation
        )
    }

    private nonisolated static func representation(for image: ImageFile) -> ComparisonSource.Representation {
        image.hasDevelopEdits || image.hasCropEdits ? .committedEdit : .original
    }

    private nonisolated static func loadPreview(for image: ImageFile) async -> PaneImage? {
        let maxPixelSize: CGFloat = 4_096
        if (image.hasDevelopEdits || image.hasCropEdits), let settings = image.cameraRawSettings,
           let rendered = await FullScreenImageCache.decodedEditedPreview(
               for: image.url,
               settings: settings,
               orientation: image.exifOrientation,
               screenMaxPx: maxPixelSize
           ) {
            return PaneImage(
                cgImage: rendered,
                isHDR: image.isNativeHDR || settings.hdrEditMode == 1
            )
        }

        guard let decoded = await FullScreenImageCache.loadDownsampledOffPool(
            from: image.url,
            maxPixelSize: maxPixelSize
        ) else { return nil }
        return PaneImage(cgImage: decoded, isHDR: image.isNativeHDR)
    }
}
