import SwiftUI
import AppKit
import QuartzCore
import os.log

nonisolated private let imageLogger = Logger(subsystem: "com.aagedal.photo-agent", category: "ImageLoading")

// MARK: - HDR Image View (CALayer-based EDR rendering)

/// Renders an NSImage using a CALayer with Extended Dynamic Range enabled.
/// This allows PQ/HLG HDR images to use the display's full brightness range
/// instead of being tonemapped to SDR.
private struct HDRImageView: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.contentsGravity = .resizeAspect
        if #available(macOS 26.0, *) {
            view.layer?.preferredDynamicRange = .high
        } else {
            view.layer?.wantsExtendedDynamicRangeContent = true
        }
        updateLayer(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        updateLayer(nsView)
    }

    private func updateLayer(_ view: NSView) {
        guard let layer = view.layer else { return }
        layer.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

// MARK: - CGFloat Clamping Extension

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Zoom Controller (bridges window events to view)

@Observable
fileprivate class ZoomController {
    var toggleZoomAction: (() -> Void)?
    var scrollZoomAction: ((CGFloat) -> Void)?
    var toggleUIAction: (() -> Void)?

    func toggleZoom() {
        toggleZoomAction?()
    }

    func scrollZoom(_ delta: CGFloat) {
        scrollZoomAction?(delta)
    }

    func toggleUI() {
        toggleUIAction?()
    }
}

// MARK: - Custom NSWindow that intercepts Escape and Space

private class FullScreenWindow: NSWindow {
    var onDismiss: (() -> Void)?
    var onSetRating: ((Int) -> Void)?
    var onSetLabel: ((Int) -> Void)?
    var onToggleZoom: (() -> Void)?
    var onScrollZoom: ((CGFloat) -> Void)?
    var onToggleUI: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        let keyCode = Int(event.keyCode)
        let flags = event.modifierFlags
        let hasCmd = flags.contains(.command)
        let hasOption = flags.contains(.option)

        // Escape or Space → dismiss
        if keyCode == 53 || keyCode == 49 {
            onDismiss?()
            return
        }

        // Z key (keyCode 6) → toggle zoom
        if keyCode == 6 && !hasCmd && !hasOption {
            onToggleZoom?()
            return
        }

        // H key (keyCode 4) → toggle UI visibility
        if keyCode == 4 && !hasCmd && !hasOption {
            onToggleUI?()
            return
        }

        let numberKeyCodes: [Int: Int] = [29: 0, 18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8]

        if hasCmd && hasOption {
            // CMD+Option+0 through CMD+Option+8 → set color label
            if let index = numberKeyCodes[keyCode], index <= 8 {
                onSetLabel?(index)
                return
            }
        } else if hasCmd {
            // CMD+0 through CMD+5 → set rating
            if let rating = numberKeyCodes[keyCode], rating <= 5 {
                onSetRating?(rating)
                return
            }
        }

        super.keyDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        // Use scroll wheel for zooming (deltaY)
        let delta = event.scrollingDeltaY
        if abs(delta) > 0.01 {
            onScrollZoom?(delta)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }
}

// MARK: - SwiftUI View

struct FullScreenImageView: View {
    @Bindable var viewModel: BrowserViewModel
    fileprivate var zoomController: ZoomController?

    @State private var currentImage: NSImage?
    @State private var isLoading = false
    @State private var fullLoadTask: Task<Void, Never>?
    @State private var showLabelPicker = false
    @State private var hideOverlays = false
    @FocusState private var isFocused: Bool

    // Image cache and prefetch
    @State private var imageCache = FullScreenImageCache()
    @State private var lastNavigationIndex: Int?

    // Zoom state
    @State private var zoomScale: CGFloat = 1.0
    @State private var lastZoomScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var isZoomedTo100: Bool = false

    private let minZoom: CGFloat = 1.0
    private let maxZoom: CGFloat = 10.0

    private var currentImageFile: ImageFile? {
        viewModel.firstSelectedImage
    }

    /// Calculate the scale factor for 100% zoom (1:1 pixel mapping)
    private func calculateZoomTo100() -> CGFloat {
        guard let image = currentImage,
              let screen = NSScreen.main else { return 1.0 }

        let imageSize = image.size
        let screenSize = screen.frame.size

        // Calculate the fit scale (how much the image is scaled down to fit)
        let fitScaleX = screenSize.width / imageSize.width
        let fitScaleY = screenSize.height / imageSize.height
        let fitScale = min(fitScaleX, fitScaleY)

        // 100% zoom means 1:1 pixel ratio, so we need to counteract the fit scale
        // If fitScale < 1, image was scaled down, so zoom100 = 1/fitScale
        // If fitScale >= 1, image already fits at 100% or smaller, just use 1.0
        if fitScale < 1.0 {
            return 1.0 / fitScale
        }
        return 1.0
    }

    func toggleZoom() {
        withAnimation(.easeInOut(duration: 0.2)) {
            if isZoomedTo100 {
                // Zoom to fit
                zoomScale = 1.0
                offset = .zero
                isZoomedTo100 = false
            } else {
                // Zoom to 100%
                zoomScale = calculateZoomTo100()
                offset = .zero
                isZoomedTo100 = true
            }
            lastZoomScale = zoomScale
            lastOffset = offset
        }
    }

    func handleScrollZoom(_ delta: CGFloat) {
        let zoomFactor: CGFloat = 1.0 + (delta * 0.02)
        let newScale = (zoomScale * zoomFactor).clamped(to: minZoom...maxZoom)

        withAnimation(.easeOut(duration: 0.1)) {
            zoomScale = newScale
            lastZoomScale = newScale

            // Reset offset if zoomed back to fit
            if newScale <= 1.0 {
                offset = .zero
                lastOffset = .zero
            }

            // Update isZoomedTo100 state
            let zoom100 = calculateZoomTo100()
            isZoomedTo100 = abs(zoomScale - zoom100) < 0.01
        }
    }

    func toggleUI() {
        hideOverlays.toggle()
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black

                if let currentImage {
                    HDRImageView(image: currentImage)
                        .aspectRatio(
                            currentImage.size.width / currentImage.size.height,
                            contentMode: .fit
                        )
                        .scaleEffect(zoomScale)
                        .offset(offset)
                        .gesture(magnifyGesture)
                        .gesture(dragGesture(in: geometry.size))
                        .onTapGesture(count: 2) {
                            toggleZoom()
                        }
                }

                if !hideOverlays {
                    if isLoading {
                        VStack {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .tint(.white)
                                    .padding(12)
                                Spacer()
                            }
                            Spacer()
                        }
                    }

                    if let file = currentImageFile {
                        // Bottom-left: star rating + color label
                        VStack {
                            Spacer()
                            HStack(spacing: 8) {
                                starRatingOverlay(for: file)
                                colorLabelOverlay(for: file)
                                Spacer()
                            }
                            .padding(.leading, 20)
                            .padding(.bottom, 20)
                        }

                        // Bottom-center: filename + zoom indicator
                        VStack {
                            Spacer()
                            HStack(spacing: 12) {
                                Text(file.filename)
                                    .font(.caption)
                                    .foregroundStyle(.white)

                                if zoomScale > 1.01 {
                                    Text("\(Int(zoomScale * 100))%")
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.7))
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.6), in: Capsule())
                            .padding(.bottom, 16)
                        }
                    }
                }
            }
        }
        .ignoresSafeArea()
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onAppear {
            isFocused = true
            // Register actions with the controller
            zoomController?.toggleZoomAction = { [self] in
                toggleZoom()
            }
            zoomController?.scrollZoomAction = { [self] delta in
                handleScrollZoom(delta)
            }
            zoomController?.toggleUIAction = { [self] in
                toggleUI()
            }
        }
        .onDisappear {
            imageCache.cancelAllPrefetch()
        }
        .onKeyPress(.leftArrow) {
            viewModel.selectPrevious()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            viewModel.selectNext()
            return .handled
        }
        .onKeyPress(.upArrow) {
            viewModel.selectPrevious()
            return .handled
        }
        .onKeyPress(.downArrow) {
            viewModel.selectNext()
            return .handled
        }
        .task(id: currentImageFile?.url) {
            // Reset zoom when changing images
            zoomScale = 1.0
            lastZoomScale = 1.0
            offset = .zero
            lastOffset = .zero
            isZoomedTo100 = false
            await loadImage()
        }
    }

    // MARK: - Gestures

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let newScale = (lastZoomScale * value.magnification).clamped(to: minZoom...maxZoom)
                zoomScale = newScale
            }
            .onEnded { value in
                lastZoomScale = zoomScale
                // Reset offset if zoomed back to fit
                if zoomScale <= 1.0 {
                    withAnimation(.easeOut(duration: 0.2)) {
                        zoomScale = 1.0
                        offset = .zero
                        lastOffset = .zero
                    }
                }
                // Update isZoomedTo100 state
                let zoom100 = calculateZoomTo100()
                isZoomedTo100 = abs(zoomScale - zoom100) < 0.01
            }
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard zoomScale > 1.0 else { return }
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { value in
                guard zoomScale > 1.0 else {
                    offset = .zero
                    lastOffset = .zero
                    return
                }
                lastOffset = offset
                // Constrain offset to prevent panning too far
                constrainOffset(in: size)
            }
    }

    private func constrainOffset(in size: CGSize) {
        guard let image = currentImage else { return }

        // Calculate the visible image size when fitted
        let imageAspect = image.size.width / image.size.height
        let screenAspect = size.width / size.height

        let fittedSize: CGSize
        if imageAspect > screenAspect {
            // Image is wider than screen
            fittedSize = CGSize(width: size.width, height: size.width / imageAspect)
        } else {
            // Image is taller than screen
            fittedSize = CGSize(width: size.height * imageAspect, height: size.height)
        }

        let scaledWidth = fittedSize.width * zoomScale
        let scaledHeight = fittedSize.height * zoomScale

        let maxOffsetX = max(0, (scaledWidth - size.width) / 2)
        let maxOffsetY = max(0, (scaledHeight - size.height) / 2)

        withAnimation(.easeOut(duration: 0.2)) {
            offset = CGSize(
                width: offset.width.clamped(to: -maxOffsetX...maxOffsetX),
                height: offset.height.clamped(to: -maxOffsetY...maxOffsetY)
            )
            lastOffset = offset
        }
    }

    private func loadImage() async {
        let filename = currentImageFile?.url.lastPathComponent ?? "nil"
        imageLogger.info("loadImage called for \(filename)")

        // Cancel any in-flight full-resolution decode from the previous image
        if fullLoadTask != nil {
            imageLogger.info("Cancelling previous full-resolution load")
        }
        fullLoadTask?.cancel()
        fullLoadTask = nil

        guard let url = currentImageFile?.url else {
            currentImage = nil
            isLoading = false
            return
        }

        // Phase 0: Instant — check cache, then fall back to thumbnail
        if let cached = imageCache.cachedImage(for: url) {
            imageLogger.info("\(filename): Phase 0 cache hit")
            currentImage = cached
            isLoading = false
            triggerPrefetch(for: url)
            return
        }

        // Cache miss — show thumbnail instantly (zero I/O) to avoid blank screen
        if let thumb = viewModel.thumbnailService.thumbnail(for: url) {
            imageLogger.info("\(filename): Phase 0 thumbnail placeholder")
            currentImage = thumb
        }

        isLoading = true

        let isRAW = SupportedImageFormats.isRaw(url: url)
        let screenScale = NSScreen.main?.backingScaleFactor ?? 2.0
        let screenLogicalPx = max(NSScreen.main?.frame.width ?? 3840, NSScreen.main?.frame.height ?? 2160)
        let screenMaxPx = screenLogicalPx * screenScale
        imageLogger.info("\(filename): isRAW=\(isRAW)")

        // Phase 1: Fast preview (~20-80ms)
        if isRAW {
            // RAW: extract embedded JPEG preview
            let previewStart = CFAbsoluteTimeGetCurrent()
            let preview = await Task.detached(priority: .userInitiated) {
                FullScreenImageCache.extractEmbeddedPreview(from: url)
            }.value
            let previewElapsed = CFAbsoluteTimeGetCurrent() - previewStart
            if let preview {
                imageLogger.info("\(filename): Phase 1 RAW preview in \(String(format: "%.1f", previewElapsed * 1000))ms (\(preview.size.width)x\(preview.size.height))")
                currentImage = preview
            } else {
                imageLogger.warning("\(filename): Phase 1 no embedded preview (\(String(format: "%.1f", previewElapsed * 1000))ms)")
            }
        } else {
            // Non-RAW: quick downsample at logical resolution (no Retina multiplier)
            let previewStart = CFAbsoluteTimeGetCurrent()
            let preview = await Task.detached(priority: .userInitiated) {
                FullScreenImageCache.loadDownsampled(from: url, maxPixelSize: screenLogicalPx)
            }.value
            let previewElapsed = CFAbsoluteTimeGetCurrent() - previewStart
            guard !Task.isCancelled else { return }
            if let preview, currentImageFile?.url == url {
                imageLogger.info("\(filename): Phase 1 preview in \(String(format: "%.1f", previewElapsed * 1000))ms (\(preview.size.width)x\(preview.size.height))")
                currentImage = preview
            }
        }

        // Phase 2: Full source resolution (for zoom and HDR fidelity)
        let fullStart = CFAbsoluteTimeGetCurrent()
        imageLogger.info("\(filename): Phase 2 starting (full resolution)")
        fullLoadTask = Task.detached(priority: .userInitiated) {
            let image = FullScreenImageCache.loadFullResolution(from: url)
            let fullElapsed = CFAbsoluteTimeGetCurrent() - fullStart
            guard !Task.isCancelled else {
                imageLogger.info("\(filename): Phase 2 cancelled after \(String(format: "%.1f", fullElapsed * 1000))ms")
                return
            }
            await MainActor.run {
                if currentImageFile?.url == url {
                    let w = image?.size.width ?? 0
                    let h = image?.size.height ?? 0
                    imageLogger.info("\(filename): Phase 2 done in \(String(format: "%.1f", fullElapsed * 1000))ms (\(w)x\(h))")
                    currentImage = image
                    isLoading = false
                    // Store in cache and trigger prefetch
                    if let image {
                        imageCache.store(image, for: url)
                    }
                    triggerPrefetch(for: url)
                } else {
                    imageLogger.info("\(filename): Phase 2 done but image changed, discarding")
                }
            }
        }
    }

    private func triggerPrefetch(for url: URL) {
        guard let currentIndex = viewModel.urlToVisibleIndex[url] else { return }

        let direction: FullScreenImageCache.NavigationDirection
        if let lastIndex = lastNavigationIndex {
            if currentIndex > lastIndex {
                direction = .forward
            } else if currentIndex < lastIndex {
                direction = .backward
            } else {
                direction = .none
            }
        } else {
            direction = .none
        }
        lastNavigationIndex = currentIndex

        let screenScale = NSScreen.main?.backingScaleFactor ?? 2.0
        let screenMaxPx = max(NSScreen.main?.frame.width ?? 3840, NSScreen.main?.frame.height ?? 2160) * screenScale
        let imageURLs = viewModel.visibleImages.map(\.url)

        imageCache.startPrefetch(
            currentIndex: currentIndex,
            images: imageURLs,
            direction: direction,
            screenMaxPx: screenMaxPx
        )
    }

    private func colorLabelOverlay(for file: ImageFile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if showLabelPicker {
                HStack(spacing: 6) {
                    ForEach(ColorLabel.allCases, id: \.self) { label in
                        Button {
                            viewModel.setLabel(label)
                            showLabelPicker = false
                        } label: {
                            if let c = label.color {
                                Circle()
                                    .fill(c)
                                    .frame(width: 20, height: 20)
                                    .overlay(
                                        Circle()
                                            .strokeBorder(.white, lineWidth: file.colorLabel == label ? 2 : 0)
                                    )
                            } else {
                                Circle()
                                    .strokeBorder(.white.opacity(0.5), lineWidth: 1)
                                    .frame(width: 20, height: 20)
                                    .overlay(
                                        file.colorLabel == .none
                                            ? Image(systemName: "xmark")
                                                .font(.caption2)
                                                .foregroundStyle(.white)
                                            : nil
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.black.opacity(0.6), in: Capsule())
                .padding(.bottom, 6)
            }

            Button {
                showLabelPicker.toggle()
            } label: {
                HStack(spacing: 4) {
                    if let color = file.colorLabel.color {
                        Circle()
                            .fill(color)
                            .frame(width: 12, height: 12)
                        Text(file.colorLabel.displayName)
                            .font(.caption)
                            .foregroundStyle(.white)
                    } else {
                        Circle()
                            .strokeBorder(.white.opacity(0.5), lineWidth: 1)
                            .frame(width: 12, height: 12)
                        Text("Label")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.6), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func starRatingOverlay(for file: ImageFile) -> some View {
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= file.starRating.rawValue ? "star.fill" : "star")
                    .font(.title3)
                    .foregroundStyle(star <= file.starRating.rawValue ? .yellow : .white.opacity(0.5))
                    .onTapGesture {
                        let newRating: StarRating = star == file.starRating.rawValue
                            ? .none
                            : StarRating(rawValue: star) ?? .none
                        viewModel.setRating(newRating)
                    }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.6), in: Capsule())
    }
}

// MARK: - Presenter (ViewModifier)

struct FullScreenPresenter: ViewModifier {
    @Bindable var viewModel: BrowserViewModel
    @State private var fullScreenWindow: FullScreenWindow?
    @State private var zoomController: ZoomController?

    func body(content: Content) -> some View {
        content
            .onChange(of: viewModel.isFullScreen) { _, newValue in
                if newValue {
                    openFullScreen()
                } else {
                    closeFullScreen()
                }
            }
    }

    private func openFullScreen() {
        guard fullScreenWindow == nil,
              let screen = NSScreen.main else { return }

        // Create zoom controller to bridge window events to the view
        let controller = ZoomController()
        zoomController = controller

        let window = FullScreenWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .mainMenu + 1
        window.isOpaque = true
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary, .ignoresCycle]
        window.hasShadow = false
        window.onDismiss = { [weak viewModel] in
            viewModel?.isFullScreen = false
        }
        window.onSetRating = { [weak viewModel] ratingValue in
            guard let rating = StarRating(rawValue: ratingValue) else { return }
            viewModel?.setRating(rating)
        }
        window.onSetLabel = { [weak viewModel] index in
            guard let label = ColorLabel.fromShortcutIndex(index) else { return }
            viewModel?.setLabel(label)
        }
        window.onToggleZoom = { [weak controller] in
            controller?.toggleZoom()
        }
        window.onScrollZoom = { [weak controller] delta in
            controller?.scrollZoom(delta)
        }
        window.onToggleUI = { [weak controller] in
            controller?.toggleUI()
        }

        let hostingView = NSHostingView(
            rootView: FullScreenImageView(viewModel: viewModel, zoomController: controller)
        )
        hostingView.wantsLayer = true
        if #available(macOS 26.0, *) {
            hostingView.layer?.preferredDynamicRange = .high
        } else {
            hostingView.layer?.wantsExtendedDynamicRangeContent = true
        }
        window.contentView = hostingView
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)

        fullScreenWindow = window
    }

    private func closeFullScreen() {
        fullScreenWindow?.orderOut(nil)
        fullScreenWindow = nil
        zoomController = nil
    }
}

extension View {
    func fullScreenImagePresenter(viewModel: BrowserViewModel) -> some View {
        modifier(FullScreenPresenter(viewModel: viewModel))
    }
}
