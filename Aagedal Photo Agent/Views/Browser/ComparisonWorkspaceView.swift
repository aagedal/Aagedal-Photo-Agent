import AppKit
import CoreGraphics
import SwiftUI

struct ComparisonWorkspaceView: View {
    let images: [ImageFile]
    let fullScreenImageCache: FullScreenImageCache
    let onClose: () -> Void

    @State private var coordinator: ComparisonCoordinator?
    @State private var renderedImages: [ComparisonPane: CGImage] = [:]
    @State private var geometries: [ComparisonPane: ComparisonPaneGeometry] = [:]
    @State private var loadError: String?
    @State private var interactionError: String?
    @State private var isLoading = true
    @State private var exactLockWasPossible = true
    @State private var loadTask: Task<Void, Never>?
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
            startLoading()
        }
        .onDisappear { loadTask?.cancel() }
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
        .onKeyPress(.tab) {
            focus(session?.focusedPane.other ?? .right)
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Image comparison workspace")
    }

    private var session: ComparisonSession? { coordinator?.session }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 12) {
            Button(action: { onClose() }) {
                Label("Close Compare", systemImage: "chevron.backward")
            }
            .help("Return to the Browser (Esc)")

            Divider().frame(height: 20)

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
                Button("Back to Browser", action: { onClose() })
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
            ContentUnavailableView(
                "Source Missing",
                systemImage: "photo.badge.exclamationmark",
                description: Text("Return to the Browser to choose another image.")
            )
        }
    }

    private func startLoading() {
        loadTask?.cancel()
        guard images.count == 2 else {
            isLoading = false
            loadError = "Select exactly two supported images in the Browser."
            return
        }

        isLoading = true
        loadError = nil
        interactionError = nil
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
                async let left = service.render(
                    imageFile: selectedImages[0],
                    settings: committedSettings(for: selectedImages[0]),
                    cache: cache,
                    maxPixelSize: maxPixelSize
                )
                async let right = service.render(
                    imageFile: selectedImages[1],
                    settings: committedSettings(for: selectedImages[1]),
                    cache: cache,
                    maxPixelSize: maxPixelSize
                )
                let (leftResult, rightResult) = try await (left, right)
                try Task.checkCancellation()

                let session = ComparisonSession(
                    origin: .browser,
                    left: leftResult.source,
                    right: rightResult.source
                )
                coordinator = try ComparisonCoordinator(session: session)
                renderedImages = [.left: leftResult.image, .right: rightResult.image]
                isLoading = false
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
        } catch {
            interactionError = error.localizedDescription
        }
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
