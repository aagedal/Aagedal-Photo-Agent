import AppKit
import CoreGraphics
import SwiftUI

struct ComparisonWorkspaceView: View {
    let images: [ImageFile]
    let navigationImages: [ImageFile]
    let availableImages: [ImageFile]
    let fullScreenImageCache: FullScreenImageCache
    let origin: ComparisonOriginWorkspace
    let initialLeftRepresentation: ComparisonRepresentation?
    let liveSource: ComparisonRenderedSource?
    let initialRightSource: ComparisonRenderedSource?
    let allowsSourceReplacement: Bool
    let allowsDeletion: Bool
    let onFocusedImageChange: (ImageFile) -> Void
    let onRequestDelete: (ImageFile) -> Void
    let onClose: (Set<URL>, URL?) -> Void

    @State private var coordinator: ComparisonCoordinator?
    @State private var renderedImages: [ComparisonPane: CGImage] = [:]
    @State private var geometries: [ComparisonPane: ComparisonPaneGeometry] = [:]
    @State private var loadError: String?
    @State private var interactionError: String?
    @State private var isLoading = true
    @State private var exactLockWasPossible = true
    @State private var loadTask: Task<Void, Never>?
    @State private var replacementTask: Task<Void, Never>?
    @State private var replacingPane: ComparisonPane?
    @State private var previousAvailableOrder: [URL] = []
    @State private var missingReplacement: [ComparisonPane: ImageFile] = [:]
    @State private var publishedCleanFeedSessionID: UUID?
    @FocusState private var workspaceFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .focusable()
        .focused($workspaceFocused)
        .onAppear {
            workspaceFocused = true
            previousAvailableOrder = availableImages.map(\.url)
            startLoading()
        }
        .onDisappear {
            loadTask?.cancel()
            replacementTask?.cancel()
            if let publishedCleanFeedSessionID {
                CleanFeedController.shared.clearComparison(
                    sessionID: publishedCleanFeedSessionID
                )
            }
        }
        .onChange(of: availableImages.map(\.url)) { _, _ in
            reconcileAvailableSources()
        }
        .onChange(of: liveSource?.source.representation.renderToken) { _, _ in
            reconcileLiveSource()
        }
        .onKeyPress(.escape) {
            closeComparison()
            return .handled
        }
        .onKeyPress(.tab) {
            focus(session?.focusedPane.other ?? .right)
            return .handled
        }
        .onKeyPress(.leftArrow) {
            replaceFocusedSource(.previous)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            replaceFocusedSource(.next)
            return .handled
        }
        .onKeyPress(.delete) {
            requestDeleteFocusedSource()
            return .handled
        }
        .onKeyPress(keys: ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "x", "s"]) {
            handleCullingShortcut($0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Image comparison workspace")
    }

    private var session: ComparisonSession? { coordinator?.session }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 12) {
            Button(action: { closeComparison() }) {
                Label("Close Compare", systemImage: "chevron.backward")
            }
            .help(origin == .develop ? "Return to Develop (Esc)" : "Return to the Browser (Esc)")

            Divider().frame(height: 20)

            if allowsSourceReplacement {
                Button { replaceFocusedSource(.previous) } label: {
                    Image(systemName: "chevron.left")
                }
                .help("Previous image in focused pane (Left Arrow)")
                .disabled(replacementTarget(.previous) == nil || replacingPane != nil)

                Button { replaceFocusedSource(.next) } label: {
                    Image(systemName: "chevron.right")
                }
                .help("Next image in focused pane (Right Arrow)")
                .disabled(replacementTarget(.next) == nil || replacingPane != nil)

                Button(role: .destructive) { requestDeleteFocusedSource() } label: {
                    Image(systemName: "trash")
                }
                .help("Move the focused image to the Trash")
                .disabled(!allowsDeletion || focusedImageFile == nil || replacingPane != nil)

                Divider().frame(height: 20)
            }

            Picker("Layout", selection: Binding(
                get: { session?.layout ?? .sideBySide },
                set: { layout in setLayout(layout) }
            )) {
                Label("Side by Side", systemImage: "rectangle.split.2x1")
                    .tag(ComparisonLayout.sideBySide)
                Label("Stacked", systemImage: "rectangle.split.1x2")
                    .tag(ComparisonLayout.stacked)
                Label("A/B", systemImage: "square.on.square")
                    .tag(ComparisonLayout.singlePane)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 350)
            .disabled(session == nil)

            if session?.layout == .singlePane {
                Picker("Visible Image", selection: Binding(
                    get: { session?.focusedPane ?? .left },
                    set: { pane in focus(pane) }
                )) {
                    Text("A").tag(ComparisonPane.left)
                    Text("B").tag(ComparisonPane.right)
                }
                .pickerStyle(.segmented)
                .frame(width: 76)
                .help("Toggle the visible comparison image")
            }

            Spacer(minLength: 8)

            if let session, session.hasDynamicRangeMismatch {
                Label("HDR / SDR", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("The two images use different display dynamic ranges")
            }

            if !exactLockWasPossible {
                Label("Edge limited", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("The panes share a center, but one image is clamped at an edge")
            }

            scaleControls
            lockControls
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var scaleControls: some View {
        HStack(spacing: 4) {
            Button { zoom(by: 1.25) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Zoom out")
            .disabled(session == nil)

            Menu {
                Button("Fit") { setScaleMode(.fit) }
                Button("100%") { setScaleMode(.actualPixels) }
            } label: {
                Text(scaleLabel)
                    .monospacedDigit()
                    .frame(minWidth: 42)
            }
            .help("Comparison scale")
            .disabled(session == nil)

            Button { zoom(by: 0.8) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoom in")
            .disabled(session == nil)
        }
    }

    @ViewBuilder
    private var lockControls: some View {
        if case let .aligning(anchor) = session?.lockState {
            Button {
                commitAlignment()
            } label: {
                Label("Save Alignment", systemImage: "checkmark")
            }
            .help("Save the offset relative to image \(anchor == .left ? "A" : "B")")
        } else {
            Button {
                toggleLock()
            } label: {
                Label(
                    session?.lockState == .locked ? "Locked" : "Unlocked",
                    systemImage: session?.lockState == .locked ? "lock.fill" : "lock.open"
                )
            }
            .help("Temporarily lock or unlock pan and zoom")
            .disabled(session == nil)

            Menu {
                Button("Align B to A") { beginAlignment(anchor: .left) }
                Button("Align A to B") { beginAlignment(anchor: .right) }
                Divider()
                Button("Reset Alignment") { resetAlignment() }
            } label: {
                Image(systemName: "scope")
            }
            .help("Set or reset a persistent comparison offset")
            .disabled(session?.hasBothSources != true)
        }
    }

    private var scaleLabel: String {
        guard let session else { return "Fit" }
        let viewport = session[session.focusedPane].viewport
        switch viewport.mode {
        case .fit: return "Fit"
        case .actualPixels: return "100%"
        case let .custom(imagePixelsPerBackingPixel):
            return "\(Int((1 / imagePixelsPerBackingPixel * 100).rounded()))%"
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack(spacing: 12) {
                ProgressView()
                Text("Preparing exact source revisions and comparison previews…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            ContentUnavailableView {
                Label("Comparison Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError)
            } actions: {
                Button("Try Again") { startLoading() }
                Button("Back to Browser", action: { closeComparison() })
            }
        } else if let session {
            comparisonLayout(session)
                .overlay(alignment: .bottom) {
                    if let interactionError {
                        Text(interactionError)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                            .padding(12)
                    }
                }
        }
    }

    @ViewBuilder
    private func comparisonLayout(_ session: ComparisonSession) -> some View {
        switch session.layout {
        case .sideBySide:
            HSplitView {
                pane(.left, session: session)
                    .frame(minWidth: 180)
                pane(.right, session: session)
                    .frame(minWidth: 180)
            }
        case .stacked:
            VSplitView {
                pane(.left, session: session)
                    .frame(minHeight: 140)
                pane(.right, session: session)
                    .frame(minHeight: 140)
            }
        case .singlePane:
            pane(session.focusedPane, session: session)
        }
    }

    @ViewBuilder
    private func pane(_ pane: ComparisonPane, session: ComparisonSession) -> some View {
        if let image = renderedImages[pane], let source = session[pane].source {
            ComparisonImagePane(
                pane: pane,
                image: image,
                source: source,
                viewport: session[pane].viewport,
                isFocused: session.focusedPane == pane,
                onFocus: { focus(pane) },
                onViewportChange: { updateViewport($0, in: pane) },
                onGeometryChange: { geometry in geometries[pane] = geometry }
            )
        } else {
            ContentUnavailableView {
                Label("Source Missing", systemImage: "photo.badge.exclamationmark")
            } description: {
                Text("The other image remains available. Replace this pane or close Compare.")
            } actions: {
                if let replacement = missingReplacement[pane] {
                    Button("Replace with \(replacement.filename)") {
                        replaceSource(in: pane, with: replacement)
                    }
                    .disabled(replacingPane != nil)
                }
                Button(origin == .develop ? "Back to Develop" : "Back to Browser", action: { closeComparison() })
            }
        }
    }

    private func startLoading() {
        loadTask?.cancel()
        guard images.count == 2 else {
            isLoading = false
            loadError = "Select exactly two supported images in the Browser."
            return
        }
        if origin == .develop, liveSource == nil {
            isLoading = true
            loadError = nil
            return
        }

        isLoading = true
        loadError = nil
        interactionError = nil
        if let publishedCleanFeedSessionID {
            CleanFeedController.shared.clearComparison(sessionID: publishedCleanFeedSessionID)
            self.publishedCleanFeedSessionID = nil
        }
        coordinator = nil
        renderedImages = [:]
        geometries = [:]
        let selectedImages = images
        let cache = fullScreenImageCache

        loadTask = Task {
            let screenPixels = (NSScreen.main?.frame.size.width ?? 2_048)
                * (NSScreen.main?.backingScaleFactor ?? 2)
            let maxPixelSize = min(max(screenPixels, 2_048), 4_096)
            let service = ComparisonRenderService()
            do {
                let renderLeft: () async throws -> ComparisonRenderedSource = {
                    if let liveSource { return liveSource }
                    let representation = initialLeftRepresentation ?? .committedEdit
                    return try await service.render(
                        imageFile: selectedImages[0],
                        settings: representation == .original
                            ? nil
                            : committedSettings(for: selectedImages[0]),
                        representation: representation,
                        cache: cache,
                        maxPixelSize: maxPixelSize
                    )
                }
                let leftResult: ComparisonRenderedSource
                let rightResult: ComparisonRenderedSource
                if let initialRightSource {
                    leftResult = try await renderLeft()
                    rightResult = initialRightSource
                } else {
                    async let pendingRight = service.render(
                        imageFile: selectedImages[1],
                        settings: committedSettings(for: selectedImages[1]),
                        cache: cache,
                        maxPixelSize: maxPixelSize
                    )
                    leftResult = try await renderLeft()
                    rightResult = try await pendingRight
                }
                try Task.checkCancellation()

                let session = ComparisonSession(
                    origin: origin,
                    left: leftResult.source,
                    right: rightResult.source
                )
                coordinator = try ComparisonCoordinator(session: session)
                renderedImages = [.left: leftResult.image, .right: rightResult.image]
                isLoading = false
                onFocusedImageChange(selectedImages[0])
                publishComparisonToCleanFeed()
            } catch is CancellationError {
                return
            } catch {
                loadError = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func committedSettings(for image: ImageFile) -> CameraRawSettings? {
        image.cameraRawSettings ?? XMPSidecarService().loadSidecar(for: image.url)?.cameraRaw
    }

    private func setLayout(_ layout: ComparisonLayout) {
        mutateCoordinator { $0.setLayout(layout) }
    }

    private func focus(_ pane: ComparisonPane) {
        mutateCoordinator { $0.setFocusedPane(pane) }
        if let image = imageFile(in: pane) {
            onFocusedImageChange(image)
        }
    }

    private var focusedImageFile: ImageFile? {
        guard let pane = session?.focusedPane else { return nil }
        return imageFile(in: pane)
    }

    private func imageFile(in pane: ComparisonPane) -> ImageFile? {
        guard let url = session?[pane].source?.revision.canonicalURL else { return nil }
        return availableImages.first { $0.url == url }
    }

    private func replacementTarget(_ direction: ComparisonNavigationDirection) -> ImageFile? {
        guard let session,
              let currentURL = session[session.focusedPane].source?.revision.canonicalURL else {
            return nil
        }
        let excludedURL = session[session.focusedPane.other].source?.revision.canonicalURL
        return ComparisonNavigationResolver.replacement(
            in: navigationImages,
            currentURL: currentURL,
            excluding: excludedURL,
            direction: direction
        )
    }

    private func replaceFocusedSource(_ direction: ComparisonNavigationDirection) {
        guard allowsSourceReplacement,
              let pane = session?.focusedPane,
              let image = replacementTarget(direction) else { return }
        replaceSource(in: pane, with: image)
    }

    private func replaceSource(in pane: ComparisonPane, with image: ImageFile) {
        guard replacingPane == nil else { return }
        replacementTask?.cancel()
        replacingPane = pane
        interactionError = nil

        let cache = fullScreenImageCache
        let expectedSessionID = session?.id
        replacementTask = Task {
            do {
                let result = try await ComparisonRenderService().render(
                    imageFile: image,
                    settings: committedSettings(for: image),
                    cache: cache,
                    maxPixelSize: comparisonMaxPixelSize
                )
                try Task.checkCancellation()
                guard coordinator?.session.id == expectedSessionID else { return }

                mutateCoordinator { $0.replaceSource(result.source, in: pane) }
                renderedImages[pane] = result.image
                geometries[pane] = nil
                missingReplacement[pane] = nil
                replacingPane = nil
                focus(pane)
                publishComparisonToCleanFeed()
            } catch is CancellationError {
                return
            } catch {
                interactionError = error.localizedDescription
                replacingPane = nil
            }
        }
    }

    private var comparisonMaxPixelSize: CGFloat {
        let screenPixels = (NSScreen.main?.frame.size.width ?? 2_048)
            * (NSScreen.main?.backingScaleFactor ?? 2)
        return min(max(screenPixels, 2_048), 4_096)
    }

    private func requestDeleteFocusedSource() {
        guard allowsDeletion, let focusedImageFile else { return }
        onRequestDelete(focusedImageFile)
    }

    private func reconcileLiveSource() {
        guard origin == .develop, let liveSource else { return }
        guard let session else {
            startLoading()
            return
        }
        guard session.left.source?.revision.canonicalURL
                == liveSource.source.revision.canonicalURL else {
            startLoading()
            return
        }
        mutateCoordinator { $0.replaceSource(liveSource.source, in: .left) }
        renderedImages[.left] = liveSource.image
        geometries[.left] = nil
        publishComparisonToCleanFeed()
    }

    private func reconcileAvailableSources() {
        guard coordinator != nil else {
            previousAvailableOrder = availableImages.map(\.url)
            return
        }
        let availableURLs = Set(availableImages.map(\.url))

        for pane in ComparisonPane.allCases {
            guard let source = session?[pane].source,
                  !availableURLs.contains(source.revision.canonicalURL) else { continue }
            let otherURL = session?[pane.other].source?.revision.canonicalURL
            missingReplacement[pane] = ComparisonNavigationResolver.closestReplacement(
                in: availableImages,
                previousOrder: previousAvailableOrder,
                missingURL: source.revision.canonicalURL,
                excluding: otherURL
            )
            mutateCoordinator { $0.markSourceMissing(in: pane) }
            renderedImages[pane] = nil
            geometries[pane] = nil
        }

        publishComparisonToCleanFeed()

        previousAvailableOrder = availableImages.map(\.url)
        if let focusedImageFile {
            onFocusedImageChange(focusedImageFile)
        }
    }

    private func closeComparison() {
        let sourceURLs: Set<URL>
        let focusedURL: URL?
        if let session {
            sourceURLs = Set(ComparisonPane.allCases.compactMap {
                session[$0].source?.revision.canonicalURL
            })
            focusedURL = session[session.focusedPane].source?.revision.canonicalURL
        } else {
            // Escape or Back can be used while initial revision capture is still running or after
            // it fails. In that case preserve the Browser selection that opened Compare.
            sourceURLs = Set(images.map(\.url))
            focusedURL = images.first?.url
        }
        onClose(sourceURLs, focusedURL)
    }

    private func updateViewport(_ viewport: ViewportState, in pane: ComparisonPane) {
        mutateCoordinator { coordinator in
            guard let transaction = try coordinator.updateViewport(
                in: pane,
                to: viewport,
                geometries: geometries
            ) else { return }
            exactLockWasPossible = transaction.exactLockWasPossible
        }
    }

    private func setScaleMode(_ mode: ViewportState.Mode) {
        guard let session else { return }
        let pane = session.focusedPane
        var viewport = session[pane].viewport
        viewport.mode = mode
        updateViewport(viewport, in: pane)
    }

    private func zoom(by multiplier: CGFloat) {
        guard let session,
              let geometry = geometries[session.focusedPane],
              let currentScale = try? geometry.resolvedScale(
                for: session[session.focusedPane].viewport
              ) else { return }
        setScaleMode(.custom(imagePixelsPerBackingPixel: min(max(currentScale * multiplier, 0.02), 64)))
    }

    private func toggleLock() {
        guard let session else { return }
        if session.lockState == .locked {
            mutateCoordinator { $0.unlock() }
        } else {
            mutateCoordinator { coordinator in
                let transaction = try coordinator.relock(
                    drivenBy: session.focusedPane,
                    geometries: geometries
                )
                exactLockWasPossible = transaction?.exactLockWasPossible ?? true
            }
        }
    }

    private func beginAlignment(anchor: ComparisonPane) {
        focus(anchor)
        mutateCoordinator { $0.beginAlignment(anchor: anchor) }
    }

    private func commitAlignment() {
        mutateCoordinator { try $0.commitAlignment(geometries: geometries) }
    }

    private func resetAlignment() {
        guard let session else { return }
        mutateCoordinator { coordinator in
            let transaction = try coordinator.resetAlignment(
                drivenBy: session.focusedPane,
                geometries: geometries
            )
            exactLockWasPossible = transaction?.exactLockWasPossible ?? true
        }
    }

    private func mutateCoordinator(
        _ mutation: (inout ComparisonCoordinator) throws -> Void
    ) {
        guard var updated = coordinator else { return }
        do {
            try mutation(&updated)
            coordinator = updated
            interactionError = nil
            publishComparisonToCleanFeed()
        } catch {
            interactionError = error.localizedDescription
        }
    }

    private func publishComparisonToCleanFeed() {
        guard let session else { return }
        CleanFeedController.shared.presentComparison(
            session: session,
            images: renderedImages
        )
        publishedCleanFeedSessionID = session.id
    }

    private func handleCullingShortcut(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isEmpty else { return .ignored }
        let characters = press.characters.lowercased()
        if let digit = characters.first?.wholeNumberValue {
            if (0...5).contains(digit), let rating = StarRating(rawValue: digit) {
                NotificationCenter.default.post(name: .setRating, object: rating)
                return .handled
            }
            if (6...9).contains(digit),
               let label = ColorLabel.fromShortcutIndex(digit - 5) {
                NotificationCenter.default.post(name: .setLabel, object: label)
                return .handled
            }
        }
        if characters == "x" {
            NotificationCenter.default.post(name: .setLabel, object: ColorLabel.trash)
            return .handled
        }
        if characters == "s" {
            NotificationCenter.default.post(name: .setLabel, object: ColorLabel.red)
            return .handled
        }
        return .ignored
    }
}

private struct ComparisonImagePane: View {
    let pane: ComparisonPane
    let image: CGImage
    let source: ComparisonSource
    let viewport: ViewportState
    let isFocused: Bool
    let onFocus: () -> Void
    let onViewportChange: (ViewportState) -> Void
    let onGeometryChange: (ComparisonPaneGeometry) -> Void

    @Environment(\.displayScale) private var displayScale
    @State private var dragStart: ViewportState?
    @State private var magnifyStart: ViewportState?

    var body: some View {
        GeometryReader { proxy in
            let paneGeometry = ComparisonPaneGeometry(
                displayedPixelSize: CGSize(width: image.width, height: image.height),
                viewSize: proxy.size,
                backingScale: displayScale
            )
            let resolved = try? viewport.geometry(
                displayedPixelSize: paneGeometry.displayedPixelSize,
                viewSize: paneGeometry.viewSize,
                backingScale: paneGeometry.backingScale
            )

            ZStack {
                Color.black
                if let resolved {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(viewport.interpolation == .nearest ? .none : .high)
                        .frame(
                            width: resolved.imageRectInView.width,
                            height: resolved.imageRectInView.height
                        )
                        .position(
                            x: resolved.imageRectInView.midX,
                            y: resolved.imageRectInView.midY
                        )
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { onFocus() }
            .gesture(dragGesture(geometry: paneGeometry))
            .simultaneousGesture(magnifyGesture(geometry: paneGeometry))
            .overlay(alignment: .topLeading) { badge }
            .overlay {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(isFocused ? Color.accentColor : .clear, lineWidth: 3)
                    .allowsHitTesting(false)
            }
            .onAppear { onGeometryChange(paneGeometry) }
            .onChange(of: proxy.size) { _, _ in onGeometryChange(paneGeometry) }
            .onChange(of: displayScale) { _, _ in onGeometryChange(paneGeometry) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Image \(pane == .left ? "A" : "B"), \(source.filename), \(source.representationLabel)"
        )
        .accessibilityAddTraits(isFocused ? .isSelected : [])
    }

    private var badge: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(pane == .left ? "A" : "B")
                    .fontWeight(.bold)
                Text(source.filename)
                    .lineLimit(1)
                Text(source.representationLabel)
                    .foregroundStyle(.secondary)
            }
            if source.dynamicRange != .unknown {
                Text(source.dynamicRange == .hdr ? "HDR" : "SDR")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .padding(10)
        .allowsHitTesting(false)
    }

    private func dragGesture(geometry: ComparisonPaneGeometry) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                onFocus()
                let start = dragStart ?? viewport
                if dragStart == nil { dragStart = start }
                guard let resolved = try? start.geometry(
                    displayedPixelSize: geometry.displayedPixelSize,
                    viewSize: geometry.viewSize,
                    backingScale: geometry.backingScale
                ) else { return }
                var requested = start
                requested.mode = .custom(
                    imagePixelsPerBackingPixel: resolved.imagePixelsPerBackingPixel
                )
                requested.normalizedCenter = CGPoint(
                    x: start.normalizedCenter.x - value.translation.width / resolved.imageRectInView.width,
                    y: start.normalizedCenter.y - value.translation.height / resolved.imageRectInView.height
                )
                onViewportChange(requested)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func magnifyGesture(geometry: ComparisonPaneGeometry) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                onFocus()
                let start = magnifyStart ?? viewport
                if magnifyStart == nil { magnifyStart = start }
                guard let resolved = try? start.geometry(
                    displayedPixelSize: geometry.displayedPixelSize,
                    viewSize: geometry.viewSize,
                    backingScale: geometry.backingScale
                ) else { return }
                var requested = start
                let magnification = max(value.magnification, 0.01)
                requested.mode = .custom(
                    imagePixelsPerBackingPixel: min(
                        max(resolved.imagePixelsPerBackingPixel / magnification, 0.02),
                        64
                    )
                )
                onViewportChange(requested)
            }
            .onEnded { _ in magnifyStart = nil }
    }
}
