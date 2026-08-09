import SwiftUI

struct ComparisonWorkspaceView: View {
    @Bindable var model: ComparisonWorkspaceModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            workspace
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label("Compare", systemImage: "rectangle.split.2x1")
                .font(.headline)

            if let session = model.session {
                Picker("Layout", selection: Binding(
                    get: { session.layout },
                    set: { model.setLayout($0) }
                )) {
                    Label("Side by Side", systemImage: "rectangle.split.2x1")
                        .tag(ComparisonLayout.sideBySide)
                    Label("Stacked", systemImage: "rectangle.split.1x2")
                        .tag(ComparisonLayout.stacked)
                    Label("A/B", systemImage: "square.on.square")
                        .tag(ComparisonLayout.single)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 340)

                if session.layout == .single {
                    Picker("Visible image", selection: Binding(
                        get: { session.focusedPane },
                        set: { model.focus($0) }
                    )) {
                        Text("A").tag(ComparisonPane.left)
                        Text("B").tag(ComparisonPane.right)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 90)
                    .help("Switch the visible comparison image")
                }

                Divider()
                    .frame(height: 20)

                viewportControls(session: session)
            }

            Spacer()

            Button("Close", systemImage: "xmark", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func viewportControls(session: ComparisonSession) -> some View {
        let focusedPane = session.focusedPane
        let viewport = session.viewport(for: focusedPane)
        let zoomPercent = model.zoomPercent(for: focusedPane) ?? 100

        return HStack(spacing: 7) {
            Button("Fit") { model.setViewportMode(.fit) }
                .buttonStyle(.bordered)
                .tint(isFit(viewport) ? .accentColor : nil)
                .help("Fit the focused image; applies to both panes while locked")

            Button("100%") { model.setViewportMode(.actualPixels) }
                .buttonStyle(.bordered)
                .tint(isActualPixels(viewport) ? .accentColor : nil)
                .help("Show one decoded image pixel per display backing pixel")

            Slider(
                value: Binding(
                    get: { Double(model.zoomPercent(for: focusedPane) ?? zoomPercent) },
                    set: { model.setZoomPercent(CGFloat($0)) }
                ),
                in: 12.5...800
            )
            .frame(width: 110)
            .help("Custom zoom")

            Text("\(Int(zoomPercent.rounded()))%")
                .font(.caption.monospacedDigit())
                .frame(width: 44, alignment: .trailing)

            Button {
                model.toggleLock()
            } label: {
                Label(
                    isLocked(session.lockState) ? "Unlock" : "Relock",
                    systemImage: isLocked(session.lockState) ? "lock.fill" : "lock.open"
                )
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .help(isLocked(session.lockState) ? "Temporarily unlock pan and zoom" : "Relock pan and zoom")

            Button {
                model.resetAlignment()
            } label: {
                Label("Reset Alignment", systemImage: "arrow.counterclockwise")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .help("Reset pane offset and scale alignment")

            Picker("Interpolation", selection: Binding(
                get: { viewport.interpolation },
                set: { model.setInterpolation($0) }
            )) {
                Text("Smooth").tag(ViewportState.Interpolation.linear)
                Text("Nearest").tag(ViewportState.Interpolation.nearest)
            }
            .labelsHidden()
            .frame(width: 88)
            .help("Image interpolation")

            if !model.lastClampedPanes.isEmpty {
                Label("Edge limited", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    .font(.caption)
                    .foregroundStyle(.yellow)
                    .help("An image edge prevented an exact locked position")
            }
        }
    }

    private func isFit(_ viewport: ViewportState) -> Bool {
        if case .fit = viewport.mode { return true }
        return false
    }

    private func isActualPixels(_ viewport: ViewportState) -> Bool {
        if case .actualPixels = viewport.mode { return true }
        return false
    }

    private func isLocked(_ state: ComparisonLockState) -> Bool {
        state == .locked || state == .lockedWithOffset
    }

    @ViewBuilder
    private var workspace: some View {
        switch model.loadState {
        case .idle, .identifyingSources:
            progressState(
                title: "Identifying sources…",
                detail: "Computing exact source revisions before the comparison opens."
            )
        case .loadingPreviews:
            progressState(
                title: "Loading comparison…",
                detail: "Preparing bounded display previews for both panes."
            )
        case .failed(let message):
            ContentUnavailableView {
                Label("Comparison Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { model.retry() }
            }
        case .ready:
            comparisonSurface
        }
    }

    private func progressState(title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var comparisonSurface: some View {
        if let session = model.session {
            switch session.layout {
            case .sideBySide:
                HSplitView {
                    pane(.left, session: session)
                        .frame(minWidth: 220)
                    pane(.right, session: session)
                        .frame(minWidth: 220)
                }
            case .stacked:
                VSplitView {
                    pane(.left, session: session)
                        .frame(minHeight: 180)
                    pane(.right, session: session)
                        .frame(minHeight: 180)
                }
            case .single:
                pane(session.focusedPane, session: session)
            }
        }
    }

    private func pane(_ pane: ComparisonPane, session: ComparisonSession) -> some View {
        ComparisonImagePane(
            pane: pane,
            source: session.source(for: pane),
            file: model.sourceFiles[pane],
            image: model.paneImages[pane],
            viewport: session.viewport(for: pane),
            isFocused: session.focusedPane == pane,
            onFocus: { model.focus(pane) },
            onSurfaceChange: { size, scale in
                model.updateSurface(for: pane, viewSize: size, backingScale: scale)
            },
            onViewportChange: { viewport in
                model.updateViewport(viewport, in: pane)
            }
        )
    }
}

private struct ComparisonImagePane: View {
    let pane: ComparisonPane
    let source: ComparisonSource
    let file: ImageFile?
    let image: ComparisonWorkspaceModel.PaneImage?
    let viewport: ViewportState
    let isFocused: Bool
    let onFocus: () -> Void
    let onSurfaceChange: (CGSize, CGFloat) -> Void
    let onViewportChange: (ViewportState) -> Void

    @Environment(\.displayScale) private var displayScale
    @State private var panStartViewport: ViewportState?
    @State private var magnifyStartViewport: ViewportState?

    var body: some View {
        ZStack {
            Color.black

            if let image {
                GeometryReader { geometry in
                    let pixelSize = CGSize(width: image.cgImage.width, height: image.cgImage.height)
                    let viewportGeometry = try? viewport.geometry(
                        displayedPixelSize: pixelSize,
                        viewSize: geometry.size,
                        backingScale: displayScale
                    )

                    if let viewportGeometry {
                        HDRImageView(
                            cgImage: image.cgImage,
                            isHDR: image.isHDR,
                            useNearestNeighbor: viewport.interpolation == .nearest,
                            onPanChanged: { translation in
                                updatePan(
                                    translation,
                                    geometry: viewportGeometry,
                                    ended: false
                                )
                            },
                            onPanEnded: { translation in
                                updatePan(
                                    translation,
                                    geometry: viewportGeometry,
                                    ended: true
                                )
                            }
                        )
                        .frame(
                            width: viewportGeometry.imageRectInView.width,
                            height: viewportGeometry.imageRectInView.height
                        )
                        .position(
                            x: viewportGeometry.imageRectInView.midX,
                            y: viewportGeometry.imageRectInView.midY
                        )
                        .gesture(magnifyGesture(geometry: viewportGeometry))
                    }

                    Color.clear
                        .allowsHitTesting(false)
                        .onAppear {
                            onSurfaceChange(geometry.size, displayScale)
                        }
                        .onChange(of: geometry.size) { _, size in
                            onSurfaceChange(size, displayScale)
                        }
                        .onChange(of: displayScale) { _, scale in
                            onSurfaceChange(geometry.size, scale)
                        }
                }
                .clipped()
            } else {
                ContentUnavailableView(
                    "Preview Unavailable",
                    systemImage: "photo.badge.exclamationmark",
                    description: Text("The source remains identified. Return to Browser to choose another pair.")
                )
                .foregroundStyle(.white, .secondary)
            }

            VStack {
                HStack(alignment: .top, spacing: 8) {
                    Text(pane == .left ? "A" : "B")
                        .font(.caption.bold())
                        .foregroundStyle(.black)
                        .frame(width: 24, height: 24)
                        .background(.white, in: Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        Text(file?.filename ?? source.revision.filenameAtCreation)
                            .font(.caption.bold())
                            .lineLimit(1)
                        Text(source.representation.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.white)

                    Spacer()

                    if source.availability == .missing {
                        Label("Missing", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                    }
                }
                .padding(10)
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                .padding(12)

                Spacer()
            }
        }
        .contentShape(Rectangle())
        .overlay {
            RoundedRectangle(cornerRadius: 2)
                .stroke(isFocused ? Color.accentColor : .clear, lineWidth: 3)
                .padding(2)
        }
        .onTapGesture(perform: onFocus)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Image \(pane == .left ? "A" : "B"), \(file?.filename ?? source.revision.filenameAtCreation), \(source.representation.label)"
        )
        .accessibilityAddTraits(isFocused ? .isSelected : [])
    }

    private func updatePan(
        _ translation: CGSize,
        geometry: ViewportGeometry,
        ended: Bool
    ) {
        guard viewport.mode != .fit else {
            panStartViewport = nil
            return
        }
        let start = panStartViewport ?? viewport
        if panStartViewport == nil { panStartViewport = start }
        var requested = start
        requested.normalizedCenter = CGPoint(
            x: start.normalizedCenter.x - translation.width / geometry.imageRectInView.width,
            y: start.normalizedCenter.y - translation.height / geometry.imageRectInView.height
        )
        onViewportChange(requested)
        if ended { panStartViewport = nil }
    }

    private func magnifyGesture(geometry: ViewportGeometry) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = magnifyStartViewport ?? viewport
                if magnifyStartViewport == nil { magnifyStartViewport = start }
                let startScale = resolvedScale(for: start, fallback: geometry.imagePixelsPerBackingPixel)
                var requested = start
                requested.mode = .custom(
                    imagePixelsPerBackingPixel: min(max(startScale / value.magnification, 0.125), 8)
                )
                onViewportChange(requested)
            }
            .onEnded { value in
                let start = magnifyStartViewport ?? viewport
                let startScale = resolvedScale(for: start, fallback: geometry.imagePixelsPerBackingPixel)
                var requested = start
                requested.mode = .custom(
                    imagePixelsPerBackingPixel: min(max(startScale / value.magnification, 0.125), 8)
                )
                onViewportChange(requested)
                magnifyStartViewport = nil
            }
    }

    private func resolvedScale(for viewport: ViewportState, fallback: CGFloat) -> CGFloat {
        switch viewport.mode {
        case .fit:
            fallback
        case .actualPixels:
            1
        case .custom(let scale):
            scale
        }
    }
}
