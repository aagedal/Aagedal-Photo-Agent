import AppKit
import CoreGraphics
import SwiftUI

private struct ComparisonWorkspaceSourceInput: Equatable {
    let availableURLs: [URL]
    let renameEvent: ComparisonRenameEvent?
    let isRenaming: Bool
}

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
    var renameEvent: ComparisonRenameEvent?
    var isRenaming = false
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
    @State private var reconciliationTask: Task<Void, Never>?
    @State private var reconciliationRequestID = UUID()
    @State private var pendingRenameBatches: [[BatchRenameExecutionPresentation.Mapping]] = []
    @State private var replacementTask: Task<Void, Never>?
    @State private var replacingPane: ComparisonPane?
    @State private var previousAvailableOrder: [URL] = []
    @State private var missingReplacement: [ComparisonPane: ImageFile] = [:]
    @State private var publishedCleanFeedSessionID: UUID?
    @FocusState private var workspaceFocused: Bool
    @Environment(AppCommandRouter.self) private var commandRouter

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            reconciliationTask?.cancel()
            reconciliationRequestID = UUID()
            if let publishedCleanFeedSessionID {
                CleanFeedController.shared.clearComparison(
                    sessionID: publishedCleanFeedSessionID
                )
            }
        }
        .onChange(of: sourceInput) { oldInput, newInput in
            let mappings = oldInput.renameEvent?.id == newInput.renameEvent?.id
                ? []
                : newInput.renameEvent?.mappings ?? []
            reconcileAvailableSources(renameMappings: mappings)
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
        .accessibilityIdentifier("comparison.workspace")
    }

    private var session: ComparisonSession? { coordinator?.session }

    private var sourceInput: ComparisonWorkspaceSourceInput {
        ComparisonWorkspaceSourceInput(
            availableURLs: availableImages.map(\.url),
            renameEvent: renameEvent,
            isRenaming: isRenaming
        )
    }

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
                .accessibilityLabel("Previous image in focused comparison pane")
                .disabled(replacementTarget(.previous) == nil || replacingPane != nil)

                Button { replaceFocusedSource(.next) } label: {
                    Image(systemName: "chevron.right")
                }
                .help("Next image in focused pane (Right Arrow)")
                .accessibilityLabel("Next image in focused comparison pane")
                .disabled(replacementTarget(.next) == nil || replacingPane != nil)

                Button(role: .destructive) { requestDeleteFocusedSource() } label: {
                    Image(systemName: "trash")
                }
                .help("Move the focused image to the Trash")
                .accessibilityLabel("Move focused comparison image to Trash")
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
                Label("Wipe", systemImage: "rectangle.lefthalf.inset.filled")
                    .tag(ComparisonLayout.wipe)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 350)
            .disabled(session == nil)

            wipeControls

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
            .accessibilityLabel("Zoom out")
            .disabled(!isZoomReady)

            Menu {
                Button("Fit") { setScaleMode(.fit) }
                Button("100%") { setScaleMode(.actualPixels) }
            } label: {
                Text(scaleLabel)
                    .monospacedDigit()
                    .frame(minWidth: 42)
            }
            .help("Comparison scale")
            .disabled(!isZoomReady)

            Button { zoom(by: 0.8) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoom in")
            .accessibilityLabel("Zoom in")
            .disabled(!isZoomReady)
        }
    }

    @ViewBuilder
    private var wipeControls: some View {
        if let session, session.layout == .wipe {
            HStack(spacing: 6) {
                Image(systemName: "arrow.left.and.right")
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { session.wipePosition },
                        set: { setWipePosition($0) }
                    ),
                    in: 0...1
                )
                .frame(width: 90)
                .help("Wipe position")
                .accessibilityLabel("Wipe position")
                .accessibilityValue("\(Int(session.wipePosition * 100)) percent")

                Image(systemName: "angle")
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { session.wipeAngleDegrees },
                        set: { setWipeAngle($0) }
                    ),
                    in: -90...90,
                    step: 1
                )
                .frame(width: 90)
                .help("Wipe angle")
                .accessibilityLabel("Wipe angle")
                .accessibilityValue("\(Int(session.wipeAngleDegrees.rounded())) degrees")
                Text("\(Int(session.wipeAngleDegrees.rounded()))°")
                    .font(.caption.monospacedDigit())
                    .frame(width: 32, alignment: .trailing)
            }
        }
    }

    private var isZoomReady: Bool {
        guard let session, geometries[session.focusedPane] != nil else { return false }
        if session.lockState == .locked, session[session.focusedPane.other].source != nil {
            return geometries[session.focusedPane.other] != nil
        }
        return true
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
            .accessibilityLabel("Comparison alignment options")
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
                Text("Preparing comparison previews…")
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    .frame(minWidth: 180, maxWidth: .infinity, maxHeight: .infinity)
                pane(.right, session: session)
                    .frame(minWidth: 180, maxWidth: .infinity, maxHeight: .infinity)
            }
        case .stacked:
            VSplitView {
                pane(.left, session: session)
                    .frame(maxWidth: .infinity, minHeight: 140, maxHeight: .infinity)
                pane(.right, session: session)
                    .frame(maxWidth: .infinity, minHeight: 140, maxHeight: .infinity)
            }
        case .wipe:
            wipePane(session)
        }
    }

    @ViewBuilder
    private func wipePane(_ session: ComparisonSession) -> some View {
        if let leftImage = renderedImages[.left],
           let rightImage = renderedImages[.right],
           let leftSource = session.left.source,
           let rightSource = session.right.source {
            WipeComparisonPane(
                leftImage: leftImage,
                rightImage: rightImage,
                leftSource: leftSource,
                rightSource: rightSource,
                leftViewport: session.left.viewport,
                rightViewport: session.right.viewport,
                focusedPane: session.focusedPane,
                wipePosition: session.wipePosition,
                wipeAngleDegrees: session.wipeAngleDegrees,
                onFocus: { focus($0) },
                onViewportChange: { viewport, pane in updateViewport(viewport, in: pane) },
                onGeometryChange: { pane, geometry in
                    geometries[pane] = geometry
                },
                onWipePositionChange: { setWipePosition($0) }
            )
        } else {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        let presentationFactsRequestID = UUID()

        loadTask = Task {
            let screenPixels = (NSScreen.main?.frame.size.width ?? 2_048)
                * (NSScreen.main?.backingScaleFactor ?? 2)
            let maxPixelSize = min(max(screenPixels, 2_048), 4_096)
            let service = ComparisonRenderService()
            do {
                let leftRepresentation = initialLeftRepresentation ?? .committedEdit
                let leftSettings: CameraRawSettings? = if liveSource != nil
                    || leftRepresentation == .original {
                    nil
                } else {
                    try await committedSettings(
                        for: selectedImages[0],
                        requestID: presentationFactsRequestID
                    )
                }
                let renderLeft: () async throws -> ComparisonRenderedSource = {
                    if let liveSource { return liveSource }
                    return try await service.render(
                        imageFile: selectedImages[0],
                        settings: leftSettings,
                        representation: leftRepresentation,
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
                    let rightSettings = try await committedSettings(
                        for: selectedImages[1],
                        requestID: presentationFactsRequestID
                    )
                    async let pendingRight = service.render(
                        imageFile: selectedImages[1],
                        settings: rightSettings,
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

    private func committedSettings(
        for image: ImageFile,
        requestID: UUID
    ) async throws -> CameraRawSettings? {
        if let settings = image.cameraRawSettings { return settings }

        let result = await FullScreenImagePresentationFactsService.shared.load(
            imageURL: image.url,
            requestID: requestID
        )
        try Task.checkCancellation()
        guard case .loaded(let facts) = result,
              facts.requestID == requestID,
              facts.imageURL == image.url else {
            throw CancellationError()
        }
        return facts.sidecarCameraRaw
    }

    private func setLayout(_ layout: ComparisonLayout) {
        geometries = [:]
        mutateCoordinator { $0.setLayout(layout) }
    }

    private func setWipePosition(_ position: CGFloat) {
        mutateCoordinator { $0.setWipePosition(position) }
    }

    private func setWipeAngle(_ angle: CGFloat) {
        mutateCoordinator { $0.setWipeAngleDegrees(angle) }
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
        let presentationFactsRequestID = UUID()
        replacementTask = Task {
            do {
                let result = try await ComparisonRenderService().render(
                    imageFile: image,
                    settings: try await committedSettings(
                        for: image,
                        requestID: presentationFactsRequestID
                    ),
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

    private func reconcileAvailableSources(
        renameMappings: [BatchRenameExecutionPresentation.Mapping] = []
    ) {
        if !renameMappings.isEmpty { pendingRenameBatches.append(renameMappings) }
        reconciliationTask?.cancel()
        let requestID = UUID()
        reconciliationRequestID = requestID
        // A folder watcher can observe temporary or destination filenames before the
        // rename result reaches this view. Retain both sources and queued mappings until
        // the sheet closes and Browser has projected the committed paths.
        guard !isRenaming else { return }
        guard let coordinator else {
            previousAvailableOrder = availableImages.map(\.url)
            return
        }
        let batches = pendingRenameBatches
        let destinations = batches.flatMap { $0.map(\.destinationURL) }
        let sourceURLs = ComparisonPane.allCases.compactMap {
            coordinator.session[$0].source?.revision.canonicalURL
        }
        let urls = sourceURLs + previousAvailableOrder + availableImages.map(\.url)
            + batches.flatMap { $0.map(\.sourceURL) }
        reconciliationTask = Task {
            do {
                let identities = try await RenameIdentityPreparationService.shared.prepare(
                    urls: urls, destinations: destinations
                )
                try Task.checkCancellation()
                guard reconciliationRequestID == requestID, var current = self.coordinator else {
                    return
                }
                let currentURLs = ComparisonPane.allCases.compactMap {
                    current.session[$0].source?.revision.canonicalURL
                }
                guard identities.contains(currentURLs) else {
                    // A pane was replaced while filesystem preparation was suspended.
                    reconcileAvailableSources()
                    return
                }
                var order = previousAvailableOrder
                for batch in batches {
                    current.reassociateSources(using: batch, identities: identities)
                    let mapped = Dictionary(uniqueKeysWithValues: batch.map {
                        (identities.lookup($0.sourceURL), $0.destinationURL.standardizedFileURL)
                    })
                    order = order.map { mapped[identities.lookup($0)] ?? $0 }
                }
                let result = ComparisonWorkspaceSourceReconciler.reconcile(
                    coordinator: current,
                    previousAvailableOrder: order,
                    availableImages: availableImages,
                    renameMappings: [],
                    identities: identities,
                    provisionalURLs: destinations
                )
                pendingRenameBatches.removeFirst(batches.count)
                publishSourceReconciliation(result)
            } catch is CancellationError {
                return
            } catch {
                interactionError = error.localizedDescription
            }
        }
    }

    private func publishSourceReconciliation(
        _ result: ComparisonWorkspaceSourceReconciliationResult
    ) {
        self.coordinator = result.coordinator
        for pane in ComparisonPane.allCases {
            missingReplacement[pane] = result.replacementURLs[pane].flatMap { replacementURL in
                // The reconciler returns the URL of an entry in this exact availability
                // snapshot. Comparing that value needs no filesystem canonicalization.
                availableImages.first {
                    $0.url == replacementURL
                }
            }
            if result.missingPanes.contains(pane) {
                renderedImages[pane] = nil
                geometries[pane] = nil
            }
        }

        publishComparisonToCleanFeed()

        previousAvailableOrder = result.previousAvailableOrder
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
        guard let action = KeyboardShortcutRouter.resolve(
            KeyboardShortcutRouteInput(
                key: press.characters,
                modifiers: KeyboardShortcutModifiers(press.modifiers),
                textEditorOwnsInput: false,
                imeHasMarkedText: false,
                isRepeat: false
            ),
            profile: KeyboardShortcutProfileRegistry.shared.selectedProfile
        ) else { return .ignored }
        switch action {
        case let .rating(value):
            guard let rating = StarRating(rawValue: value) else { return .ignored }
            commandRouter.send(.setRating(rating))
        case let .colorLabel(index):
            guard let label = ColorLabel.fromShortcutIndex(index) else { return .ignored }
            commandRouter.send(.setLabel(label))
        }
        return .handled
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
    @State private var pointerLocation: CGPoint?
    @State private var latestGeometry: ComparisonPaneGeometry?
    @State private var latestViewport: ViewportState?
    @State private var scrollEventMonitor: Any?

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
                    ComparisonImageLayer(
                        image: image,
                        viewport: viewport,
                        geometry: resolved
                    )
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { onFocus() }
            .gesture(dragGesture(geometry: paneGeometry))
            .simultaneousGesture(magnifyGesture(geometry: paneGeometry))
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case let .active(location): pointerLocation = location
                case .ended: pointerLocation = nil
                }
            }
            .overlay(alignment: .topLeading) { badge }
            .overlay {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(isFocused ? Color.accentColor : .clear, lineWidth: 3)
                    .allowsHitTesting(false)
            }
            .onAppear {
                latestGeometry = paneGeometry
                latestViewport = viewport
                onGeometryChange(paneGeometry)
                installScrollEventMonitor()
            }
            .onDisappear { removeScrollEventMonitor() }
            .onChange(of: proxy.size) { _, _ in
                latestGeometry = paneGeometry
                onGeometryChange(paneGeometry)
            }
            .onChange(of: displayScale) { _, _ in
                latestGeometry = paneGeometry
                onGeometryChange(paneGeometry)
            }
            .onChange(of: paneGeometry.displayedPixelSize) { _, _ in
                latestGeometry = paneGeometry
                onGeometryChange(paneGeometry)
            }
            .onChange(of: viewport) { _, newViewport in
                latestViewport = newViewport
            }
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

    private func installScrollEventMonitor() {
        guard scrollEventMonitor == nil else { return }
        scrollEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let pointerLocation,
                  let geometry = latestGeometry,
                  let viewport = latestViewport else { return event }
            guard event.phase != [] || event.momentumPhase == [] else { return event }
            let delta = event.scrollingDeltaY
            guard abs(delta) > 0.01 else { return event }
            onFocus()
            onViewportChange(
                zoomedViewport(
                    viewport,
                    by: exp(delta * 0.01),
                    anchoredAt: pointerLocation,
                    geometry: geometry
                )
            )
            return nil
        }
    }

    private func removeScrollEventMonitor() {
        guard let scrollEventMonitor else { return }
        NSEvent.removeMonitor(scrollEventMonitor)
        self.scrollEventMonitor = nil
    }
}

private struct WipeComparisonPane: View {
    let leftImage: CGImage
    let rightImage: CGImage
    let leftSource: ComparisonSource
    let rightSource: ComparisonSource
    let leftViewport: ViewportState
    let rightViewport: ViewportState
    let focusedPane: ComparisonPane
    let wipePosition: CGFloat
    let wipeAngleDegrees: CGFloat
    let onFocus: (ComparisonPane) -> Void
    let onViewportChange: (ViewportState, ComparisonPane) -> Void
    let onGeometryChange: (ComparisonPane, ComparisonPaneGeometry) -> Void
    let onWipePositionChange: (CGFloat) -> Void

    @Environment(\.displayScale) private var displayScale
    @State private var dragStart: ViewportState?
    @State private var magnifyStart: ViewportState?
    @State private var pointerLocation: CGPoint?
    @State private var latestGeometries: [ComparisonPane: ComparisonPaneGeometry] = [:]
    @State private var latestViewports: [ComparisonPane: ViewportState] = [:]
    @State private var latestFocusedPane: ComparisonPane = .left
    @State private var scrollEventMonitor: Any?

    var body: some View {
        GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)
            let leftGeometry = ComparisonPaneGeometry(
                displayedPixelSize: CGSize(width: leftImage.width, height: leftImage.height),
                viewSize: proxy.size,
                backingScale: displayScale
            )
            let rightGeometry = ComparisonPaneGeometry(
                displayedPixelSize: CGSize(width: rightImage.width, height: rightImage.height),
                viewSize: proxy.size,
                backingScale: displayScale
            )
            let resolvedLeft = try? leftViewport.geometry(
                displayedPixelSize: leftGeometry.displayedPixelSize,
                viewSize: leftGeometry.viewSize,
                backingScale: leftGeometry.backingScale
            )
            let resolvedRight = try? rightViewport.geometry(
                displayedPixelSize: rightGeometry.displayedPixelSize,
                viewSize: rightGeometry.viewSize,
                backingScale: rightGeometry.backingScale
            )

            ZStack {
                Color.black
                if let resolvedRight {
                    ComparisonImageLayer(
                        image: rightImage,
                        viewport: rightViewport,
                        geometry: resolvedRight
                    )
                }
                if let resolvedLeft {
                    ZStack {
                        ComparisonImageLayer(
                            image: leftImage,
                            viewport: leftViewport,
                            geometry: resolvedLeft
                        )
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .mask(
                        ComparisonWipeMask(
                            position: wipePosition,
                            angleDegrees: wipeAngleDegrees
                        )
                    )
                }

                ComparisonWipeDivider(
                    position: wipePosition,
                    angleDegrees: wipeAngleDegrees
                )
                .stroke(.white.opacity(0.95), style: StrokeStyle(lineWidth: 2, dash: [7, 4]))
                .shadow(color: .black.opacity(0.8), radius: 2)
                .allowsHitTesting(false)

                if let segment = ComparisonWipeGeometry.dividerSegment(
                    in: rect,
                    position: wipePosition,
                    angleDegrees: wipeAngleDegrees
                ) {
                    Circle()
                        .fill(.regularMaterial)
                        .overlay {
                            Image(systemName: "arrow.left.and.right")
                                .font(.caption.bold())
                        }
                        .frame(width: 34, height: 34)
                        .position(
                            x: (segment.0.x + segment.1.x) / 2,
                            y: (segment.0.y + segment.1.y) / 2
                        )
                        .gesture(wipeDragGesture(in: rect))
                        .help("Drag to move the wipe")
                }
            }
            .clipped()
            .coordinateSpace(name: "comparisonWipe")
            .contentShape(Rectangle())
            .gesture(panGesture(geometry: focusedPane == .left ? leftGeometry : rightGeometry))
            .simultaneousGesture(
                magnifyGesture(geometry: focusedPane == .left ? leftGeometry : rightGeometry)
            )
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case let .active(location): pointerLocation = location
                case .ended: pointerLocation = nil
                }
            }
            .overlay(alignment: .topLeading) {
                sourceBadge(pane: .left, source: leftSource)
                    .onTapGesture { onFocus(.left) }
            }
            .overlay(alignment: .topTrailing) {
                sourceBadge(pane: .right, source: rightSource)
                    .onTapGesture { onFocus(.right) }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .allowsHitTesting(false)
            }
            .onAppear {
                updateGeometries(left: leftGeometry, right: rightGeometry)
                latestViewports = [.left: leftViewport, .right: rightViewport]
                latestFocusedPane = focusedPane
                installScrollEventMonitor()
            }
            .onDisappear { removeScrollEventMonitor() }
            .onChange(of: proxy.size) { _, _ in
                updateGeometries(left: leftGeometry, right: rightGeometry)
            }
            .onChange(of: displayScale) { _, _ in
                updateGeometries(left: leftGeometry, right: rightGeometry)
            }
            .onChange(of: leftGeometry.displayedPixelSize) { _, _ in
                updateGeometries(left: leftGeometry, right: rightGeometry)
            }
            .onChange(of: rightGeometry.displayedPixelSize) { _, _ in
                updateGeometries(left: leftGeometry, right: rightGeometry)
            }
            .onChange(of: leftViewport) { _, newViewport in
                latestViewports[.left] = newViewport
            }
            .onChange(of: rightViewport) { _, newViewport in
                latestViewports[.right] = newViewport
            }
            .onChange(of: focusedPane) { _, newPane in
                latestFocusedPane = newPane
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Image comparison wipe")
    }

    private func sourceBadge(pane: ComparisonPane, source: ComparisonSource) -> some View {
        HStack(spacing: 6) {
            Text(pane == .left ? "A" : "B").fontWeight(.bold)
            Text(source.filename).lineLimit(1)
            Text(source.representationLabel).foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(focusedPane == pane ? Color.accentColor : .clear, lineWidth: 2)
        }
        .padding(10)
        .help("Focus image \(pane == .left ? "A" : "B")")
    }

    private func updateGeometries(
        left: ComparisonPaneGeometry,
        right: ComparisonPaneGeometry
    ) {
        latestGeometries = [.left: left, .right: right]
        onGeometryChange(.left, left)
        onGeometryChange(.right, right)
    }

    private func panGesture(geometry: ComparisonPaneGeometry) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let viewport = focusedPane == .left ? leftViewport : rightViewport
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
                onViewportChange(requested, focusedPane)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func magnifyGesture(geometry: ComparisonPaneGeometry) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let viewport = focusedPane == .left ? leftViewport : rightViewport
                let start = magnifyStart ?? viewport
                if magnifyStart == nil { magnifyStart = start }
                onViewportChange(
                    zoomedViewport(
                        start,
                        by: max(value.magnification, 0.01),
                        anchoredAt: CGPoint(
                            x: geometry.viewSize.width / 2,
                            y: geometry.viewSize.height / 2
                        ),
                        geometry: geometry
                    ),
                    focusedPane
                )
            }
            .onEnded { _ in magnifyStart = nil }
    }

    private func wipeDragGesture(in rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("comparisonWipe"))
            .onChanged { value in
                onWipePositionChange(
                    ComparisonWipeGeometry.position(
                        for: value.location,
                        in: rect,
                        angleDegrees: wipeAngleDegrees
                    )
                )
            }
    }

    private func installScrollEventMonitor() {
        guard scrollEventMonitor == nil else { return }
        scrollEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let pointerLocation,
                  let geometry = latestGeometries[latestFocusedPane],
                  let viewport = latestViewports[latestFocusedPane] else { return event }
            guard event.phase != [] || event.momentumPhase == [] else { return event }
            let delta = event.scrollingDeltaY
            guard abs(delta) > 0.01 else { return event }
            onViewportChange(
                zoomedViewport(
                    viewport,
                    by: exp(delta * 0.01),
                    anchoredAt: pointerLocation,
                    geometry: geometry
                ),
                latestFocusedPane
            )
            return nil
        }
    }

    private func removeScrollEventMonitor() {
        guard let scrollEventMonitor else { return }
        NSEvent.removeMonitor(scrollEventMonitor)
        self.scrollEventMonitor = nil
    }
}

private struct ComparisonImageLayer: View {
    let image: CGImage
    let viewport: ViewportState
    let geometry: ViewportGeometry

    var body: some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(viewport.interpolation == .nearest ? .none : .high)
            .frame(
                width: geometry.imageRectInView.width,
                height: geometry.imageRectInView.height
            )
            .position(
                x: geometry.imageRectInView.midX,
                y: geometry.imageRectInView.midY
            )
    }
}

nonisolated private struct ComparisonWipeMask: Shape {
    var position: CGFloat
    var angleDegrees: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(position, angleDegrees) }
        set {
            position = newValue.first
            angleDegrees = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let points = ComparisonWipeGeometry.maskPolygon(
            in: rect,
            position: position,
            angleDegrees: angleDegrees
        )
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }
}

nonisolated private struct ComparisonWipeDivider: Shape {
    var position: CGFloat
    var angleDegrees: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(position, angleDegrees) }
        set {
            position = newValue.first
            angleDegrees = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let segment = ComparisonWipeGeometry.dividerSegment(
            in: rect,
            position: position,
            angleDegrees: angleDegrees
        ) else { return path }
        path.move(to: segment.0)
        path.addLine(to: segment.1)
        return path
    }
}

private func zoomedViewport(
    _ viewport: ViewportState,
    by magnification: CGFloat,
    anchoredAt anchor: CGPoint,
    geometry: ComparisonPaneGeometry
) -> ViewportState {
    guard let resolved = try? viewport.geometry(
        displayedPixelSize: geometry.displayedPixelSize,
        viewSize: geometry.viewSize,
        backingScale: geometry.backingScale
    ) else { return viewport }
    let newScale = min(max(
        resolved.imagePixelsPerBackingPixel / max(magnification, 0.01),
        0.02
    ), 64)
    let normalizedAnchor = resolved.normalizedDisplayPoint(fromViewPoint: anchor)
    let newImageSize = CGSize(
        width: geometry.displayedPixelSize.width / newScale / geometry.backingScale,
        height: geometry.displayedPixelSize.height / newScale / geometry.backingScale
    )
    let viewCenter = CGPoint(x: geometry.viewSize.width / 2, y: geometry.viewSize.height / 2)
    var requested = viewport
    requested.mode = .custom(imagePixelsPerBackingPixel: newScale)
    requested.normalizedCenter = CGPoint(
        x: normalizedAnchor.x - (anchor.x - viewCenter.x) / newImageSize.width,
        y: normalizedAnchor.y - (anchor.y - viewCenter.y) / newImageSize.height
    )
    return requested
}
