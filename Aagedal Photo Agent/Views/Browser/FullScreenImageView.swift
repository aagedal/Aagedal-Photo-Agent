import SwiftUI
import AppKit
import QuartzCore
import ImageIO
import CoreImage
import os.log

nonisolated private let imageLogger = Logger(subsystem: "com.aagedal.photo-agent", category: "ImageLoading")

// MARK: - Loaded Image

private struct LoadedImage {
    let cgImage: CGImage
    let size: CGSize
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
    var toggleZoomAction: ((CGPoint) -> Void)?
    var scrollZoomAction: ((CGFloat, CGPoint) -> Void)?
    var toggleUIAction: (() -> Void)?
    var toggleScalingAction: (() -> Void)?
    var toggleFaceRectanglesAction: (() -> Void)?
    var toggleEditRenderingAction: (() -> Void)?

    func toggleZoom(at location: CGPoint) {
        toggleZoomAction?(location)
    }

    func scrollZoom(_ delta: CGFloat, at location: CGPoint) {
        scrollZoomAction?(delta, location)
    }

    func toggleUI() {
        toggleUIAction?()
    }

    func toggleScaling() {
        toggleScalingAction?()
    }

    func toggleFaceRectangles() {
        toggleFaceRectanglesAction?()
    }

    func toggleEditRendering() {
        toggleEditRenderingAction?()
    }
}

// MARK: - Custom NSWindow that intercepts Escape and Space

private class FullScreenWindow: NSWindow {
    var onDismiss: (() -> Void)?
    var onSetRating: ((Int) -> Void)?
    var onSetLabel: ((Int) -> Void)?
    var onToggleZoom: ((CGPoint) -> Void)?
    var onScrollZoom: ((CGFloat, CGPoint) -> Void)?
    var onToggleUI: (() -> Void)?
    var onToggleScaling: (() -> Void)?
    var onToggleFaceRectangles: (() -> Void)?
    var onToggleEditRendering: (() -> Void)?

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

        // Z key (keyCode 6) → toggle zoom towards cursor
        if keyCode == 6 && !hasCmd && !hasOption {
            let mouseLoc = NSEvent.mouseLocation
            // Convert screen coordinates to window coordinates (top-left origin)
            let windowLoc = CGPoint(
                x: mouseLoc.x - frame.origin.x,
                y: frame.height - (mouseLoc.y - frame.origin.y)
            )
            onToggleZoom?(windowLoc)
            return
        }

        // H key (keyCode 4) → toggle UI visibility
        if keyCode == 4 && !hasCmd && !hasOption {
            onToggleUI?()
            return
        }

        // S key (keyCode 1) → toggle scaling filter
        if keyCode == 1 && !hasCmd && !hasOption {
            onToggleScaling?()
            return
        }

        // G key (keyCode 5) → toggle face rectangles
        if keyCode == 5 && !hasCmd && !hasOption {
            onToggleFaceRectangles?()
            return
        }

        // E key (keyCode 14) → toggle edit rendering
        if keyCode == 14 && !hasCmd && !hasOption {
            onToggleEditRendering?()
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
        // Use scroll wheel for zooming (deltaY), anchored at mouse position
        let delta = event.scrollingDeltaY
        if abs(delta) > 0.01 {
            // Convert mouse location to top-left origin (SwiftUI coordinate space)
            let windowLoc = event.locationInWindow
            let flipped = CGPoint(x: windowLoc.x, y: frame.height - windowLoc.y)
            onScrollZoom?(delta, flipped)
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

    @State private var currentImage: LoadedImage?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var fullLoadTask: Task<Void, Never>?
    @State private var fullResTask: Task<Void, Never>?
    @State private var isFullResLoaded = false
    @State private var showLabelPicker = false
    @State private var hideOverlays = false
    @FocusState private var isFocused: Bool

    // Image cache and prefetch
    private var imageCache: FullScreenImageCache { viewModel.fullScreenImageCache }
    @State private var lastNavigationIndex: Int?

    // Edit rendering state (E key toggle)
    @State private var renderEdits: Bool = false

    // Face overlay state
    @State private var showFaceRectangles: Bool = false

    // Zoom state
    @State private var zoomScale: CGFloat = 1.0
    @State private var lastZoomScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var isZoomedTo100: Bool = false
    @State private var sourcePixelSize: CGSize?
    @State private var useNearestNeighbor: Bool = false
    @State private var lastOrientationURL: URL?

    /// Minimum zoom allows zooming out to 1:1 pixel mapping for small images.
    private var minZoom: CGFloat {
        min(calculateZoomTo100(), 1.0)
    }
    private let maxZoom: CGFloat = 40.0

    private var currentImageFile: ImageFile? {
        viewModel.firstSelectedImage
    }

    private var isHDR: Bool {
        renderEdits && currentImageFile?.cameraRawSettings?.hdrEditMode == 1
    }

    /// Calculate the scale factor for 100% zoom (1:1 pixel mapping).
    /// Uses the original source file pixel dimensions, not the loaded NSImage size.
    private func calculateZoomTo100() -> CGFloat {
        guard let screen = NSScreen.main else { return 1.0 }

        // Use source pixel dimensions for accurate 100% calculation
        let imagePixels: CGSize
        if let src = sourcePixelSize {
            imagePixels = src
        } else if let image = currentImage {
            imagePixels = image.size
        } else {
            return 1.0
        }

        let screenPoints = screen.frame.size
        let backingScale = screen.backingScaleFactor

        // The image is fitted to screen points. At 100% zoom, 1 source pixel = 1 screen pixel.
        // fitScale = how much the image is scaled to fit the screen in points.
        let fitScaleX = screenPoints.width / imagePixels.width
        let fitScaleY = screenPoints.height / imagePixels.height
        let fitScale = min(fitScaleX, fitScaleY)

        // At zoomScale=1, the image fills fitScale * imagePixels points.
        // Each point = backingScale pixels. So displayed pixels = fitScale * imagePixels * backingScale.
        // For 1:1 pixel mapping: fitScale * zoom100 * backingScale = 1
        // zoom100 = 1 / (fitScale * backingScale)
        let zoom100 = 1.0 / (fitScale * backingScale)
        return zoom100
    }

    func toggleZoom(at cursorLocation: CGPoint) {
        guard let screen = NSScreen.main else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            if isZoomedTo100 {
                // Zoom to fit
                zoomScale = 1.0
                offset = .zero
                isZoomedTo100 = false
            } else {
                // Zoom to 100% anchored at cursor
                let oldScale = zoomScale
                let newScale = calculateZoomTo100()

                let viewCenter = CGPoint(x: screen.frame.width / 2, y: screen.frame.height / 2)
                let cursorFromCenter = CGSize(
                    width: cursorLocation.x - viewCenter.x,
                    height: cursorLocation.y - viewCenter.y
                )
                let ratio = newScale / oldScale
                offset = CGSize(
                    width: offset.width * ratio + cursorFromCenter.width * (1 - ratio),
                    height: offset.height * ratio + cursorFromCenter.height * (1 - ratio)
                )

                zoomScale = newScale
                isZoomedTo100 = true
            }
            lastZoomScale = zoomScale
            lastOffset = offset
        }
        loadFullResIfNeeded()
    }

    func handleScrollZoom(_ delta: CGFloat, at cursorLocation: CGPoint) {
        guard let screen = NSScreen.main else { return }
        let zoomFactor: CGFloat = 1.0 + (delta * 0.02)
        let oldScale = zoomScale
        let newScale = (oldScale * zoomFactor).clamped(to: minZoom...maxZoom)
        guard newScale != oldScale else { return }

        // Cursor position relative to view center
        let viewCenter = CGPoint(x: screen.frame.width / 2, y: screen.frame.height / 2)
        let cursorFromCenter = CGSize(
            width: cursorLocation.x - viewCenter.x,
            height: cursorLocation.y - viewCenter.y
        )

        // To keep the content under the cursor fixed:
        // cursor_content = (cursorFromCenter - offset) / oldScale
        // After zoom: newOffset = cursorFromCenter - cursor_content * newScale
        // Simplifies to: newOffset = offset * (newScale / oldScale) + cursorFromCenter * (1 - newScale / oldScale)
        let ratio = newScale / oldScale
        let newOffset = CGSize(
            width: offset.width * ratio + cursorFromCenter.width * (1 - ratio),
            height: offset.height * ratio + cursorFromCenter.height * (1 - ratio)
        )

        withAnimation(.easeOut(duration: 0.1)) {
            zoomScale = newScale
            lastZoomScale = newScale

            // At fit level (1.0) or below, no panning is needed
            if newScale <= 1.0 {
                offset = .zero
                lastOffset = .zero
            } else {
                offset = newOffset
                lastOffset = newOffset
            }

            let zoom100 = calculateZoomTo100()
            isZoomedTo100 = abs(zoomScale - zoom100) < 0.01
        }
        loadFullResIfNeeded()
    }

    func toggleUI() {
        hideOverlays.toggle()
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black

                if let currentImage {
                    HDRImageView(cgImage: currentImage.cgImage, isHDR: isHDR, useNearestNeighbor: useNearestNeighbor)
                        .aspectRatio(
                            currentImage.size.width / currentImage.size.height,
                            contentMode: .fit
                        )
                        .scaleEffect(zoomScale)
                        .offset(offset)
                        .gesture(magnifyGesture)
                        .gesture(dragGesture(in: geometry.size))
                        .onTapGesture(count: 2) {
                            let mouse = NSEvent.mouseLocation
                            let screenFrame = NSScreen.main?.frame ?? .zero
                            let location = CGPoint(
                                x: mouse.x - screenFrame.origin.x,
                                y: screenFrame.height - (mouse.y - screenFrame.origin.y)
                            )
                            toggleZoom(at: location)
                        }

                    // Face rectangles overlay (between image and UI overlays)
                    if showFaceRectangles && !hideOverlays {
                        faceRectanglesOverlay(imageSize: currentImage.size, containerSize: geometry.size)
                            .scaleEffect(zoomScale)
                            .offset(offset)
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

                    if let loadError, currentImage == nil {
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.largeTitle)
                                .foregroundStyle(.white.opacity(0.6))
                            Text(loadError)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }

                    if let file = currentImageFile {
                        // Top-right: crop / edit / C2PA badges
                        if file.hasC2PA || file.hasDevelopEdits || file.hasCropEdits
                            || file.hasPendingMetadataChanges || file.cameraRawSettings?.hdrEditMode == 1 {
                            VStack {
                                HStack {
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 8) {
                                        if file.hasC2PA {
                                            Label("C2PA", systemImage: "checkmark.seal.fill")
                                                .font(.caption)
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 6)
                                                .background(.blue.opacity(0.8), in: Capsule())
                                        }
                                        if file.hasDevelopEdits {
                                            Label("Edited", systemImage: "slider.horizontal.3")
                                                .font(.caption)
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 6)
                                                .background(.orange.opacity(0.8), in: Capsule())
                                        }
                                        if file.hasCropEdits {
                                            Label("Cropped", systemImage: "crop")
                                                .font(.caption)
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 6)
                                                .background(.green.opacity(0.8), in: Capsule())
                                        }
                                        if file.cameraRawSettings?.hdrEditMode == 1 {
                                            Label("HDR", systemImage: "sun.max.fill")
                                                .font(.caption)
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 6)
                                                .background(.purple.opacity(0.8), in: Capsule())
                                        }
                                        if file.hasPendingMetadataChanges {
                                            Label("Pending", systemImage: "circle.fill")
                                                .font(.caption)
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 6)
                                                .background(.yellow.opacity(0.8), in: Capsule())
                                        }
                                    }
                                    .padding(.trailing, 20)
                                    .padding(.top, 20)
                                }
                                Spacer()
                            }
                        }

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

                        // Bottom-center: filename + indicators
                        VStack {
                            Spacer()
                            HStack(spacing: 12) {
                                Text(file.filename)
                                    .font(.caption)
                                    .foregroundStyle(.white)

                                if isZoomedTo100 {
                                    Text("1:1")
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.7))
                                } else if abs(zoomScale - 1.0) > 0.01 {
                                    Text("\(Int(zoomScale * 100))%")
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.7))
                                }

                                if showFaceRectangles {
                                    Text("Faces")
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.7))
                                }

                                if renderEdits {
                                    Text("Edits")
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.7))
                                }

                                if useNearestNeighbor {
                                    Text("NN")
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
            // Initialize render edits from UserDefaults
            let previewMode = UserDefaults.standard.string(forKey: UserDefaultsKeys.previewMode) ?? "performance"
            renderEdits = previewMode == "editing"
            // Initialize face rectangles from context (visible by default when opened from face view)
            showFaceRectangles = viewModel.fullScreenFaceContext?.highlightedFaceID != nil
            // Register actions with the controller
            zoomController?.toggleZoomAction = { [self] location in
                toggleZoom(at: location)
            }
            zoomController?.scrollZoomAction = { [self] delta, location in
                handleScrollZoom(delta, at: location)
            }
            zoomController?.toggleUIAction = { [self] in
                toggleUI()
            }
            zoomController?.toggleScalingAction = { [self] in
                useNearestNeighbor.toggle()
            }
            zoomController?.toggleFaceRectanglesAction = { [self] in
                showFaceRectangles.toggle()
            }
            zoomController?.toggleEditRenderingAction = { [self] in
                renderEdits.toggle()
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
        .task(id: "\(currentImageFile?.url.absoluteString ?? "nil")|\(renderEdits)") {
            // Reset zoom when changing images
            zoomScale = 1.0
            lastZoomScale = 1.0
            offset = .zero
            lastOffset = .zero
            isZoomedTo100 = false
            isFullResLoaded = false
            fullResTask?.cancel()
            fullResTask = nil
            lastOrientationURL = currentImageFile?.url
            await loadImage()
        }
        .onChange(of: renderEdits) {
            imageCache.clearAll()
            imageCache.cancelAllPrefetch()
            // Clear the displayed image immediately so the stale render
            // doesn't linger while the new version loads.
            currentImage = nil
        }
        .onChange(of: currentImageFile?.exifOrientation) { oldValue, newValue in
            // Only apply in-place rotation when the same image was rotated,
            // not when navigating to a different image with a different orientation.
            let url = currentImageFile?.url
            guard url == lastOrientationURL else {
                lastOrientationURL = url
                return
            }
            guard let oldValue, let newValue, oldValue != newValue,
                  let current = currentImage,
                  let url else { return }
            let clockwise = ImageFile.orientationAfterClockwiseRotation(oldValue) == newValue
            if let rotated = Self.rotateCGImage90(current.cgImage, clockwise: clockwise) {
                currentImage = makeLoadedImage(from: rotated)
            }
            imageCache.invalidateImage(for: url)
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
                // Reset offset if at or above fit level (1.0) — panning only makes sense above fit
                if zoomScale <= 1.0 {
                    withAnimation(.easeOut(duration: 0.2)) {
                        offset = .zero
                        lastOffset = .zero
                    }
                }
                // Update isZoomedTo100 state
                let zoom100 = calculateZoomTo100()
                isZoomedTo100 = abs(zoomScale - zoom100) < 0.01
                loadFullResIfNeeded()
            }
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                // Only allow panning when zoomed beyond fit level
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

    /// Apply CameraRaw adjustments + crop to a CGImage, preserving HDR color space.
    nonisolated private static func applyCameraRaw(to cgImage: CGImage, settings: CameraRawSettings?, exifOrientation: Int = 1) -> CGImage {
        guard let settings else { return cgImage }
        let ciImage = CIImage(cgImage: cgImage)
        let processed = CameraRawApproximation.applyWithCrop(to: ciImage, settings: settings, exifOrientation: exifOrientation)
        let extent = processed.extent
        guard extent.width > 0, extent.height > 0 else { return cgImage }

        guard let result = CameraRawApproximation.ciContext.createCGImage(
            processed,
            from: extent,
            format: .RGBAh,
            colorSpace: CameraRawApproximation.workingColorSpace
        ) else {
            return cgImage
        }
        return result
    }

    /// Apply CameraRaw adjustments + crop to a CIImage source, preserving HDR float values.
    nonisolated private static func applyCameraRaw(to ciImage: CIImage, settings: CameraRawSettings?, exifOrientation: Int = 1) -> CGImage? {
        let processed: CIImage
        if let settings {
            processed = CameraRawApproximation.applyWithCrop(to: ciImage, settings: settings, exifOrientation: exifOrientation)
        } else {
            processed = ciImage
        }
        let extent = processed.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        return CameraRawApproximation.ciContext.createCGImage(
            processed, from: extent,
            format: .RGBAh,
            colorSpace: CameraRawApproximation.workingColorSpace
        )
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
            sourcePixelSize = nil
            isLoading = false
            loadError = nil
            return
        }
        loadError = nil

        // Non-image files: show system icon and return
        guard SupportedImageFormats.isSupported(url: url) else {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            if let cgIcon = icon.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                currentImage = makeLoadedImage(from: cgIcon)
            }
            sourcePixelSize = nil
            isLoading = false
            return
        }

        let cameraRaw = renderEdits ? currentImageFile?.cameraRawSettings : nil
        let imageOrientation = currentImageFile?.exifOrientation ?? 1

        // Read source pixel dimensions (cheap metadata-only, no pixel decode)
        // EXIF orientations 5-8 swap width/height after transform
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let pw = props[kCGImagePropertyPixelWidth] as? Int,
           let ph = props[kCGImagePropertyPixelHeight] as? Int {
            let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
            let swapped = orientation >= 5 && orientation <= 8
            var rawSize = swapped
                ? CGSize(width: CGFloat(ph), height: CGFloat(pw))
                : CGSize(width: CGFloat(pw), height: CGFloat(ph))

            // Adjust for crop if present (only when rendering edits)
            if renderEdits, let crop = cameraRaw?.crop, !(crop.isEmpty) {
                let displayCrop = crop.transformedForDisplay(orientation: orientation)
                let aabbW = ((displayCrop.right ?? 1) - (displayCrop.left ?? 0)) * rawSize.width
                let aabbH = ((displayCrop.bottom ?? 1) - (displayCrop.top ?? 0)) * rawSize.height
                let angle = crop.angle ?? 0
                if aabbW > 1, aabbH > 1 {
                    if abs(angle) > 0.0001 {
                        // Forward-project AABB to actual crop dims (matches CropOverlayView.forwardProjectDims)
                        let r = angle * .pi / 180.0
                        let cosR = cos(r)
                        let sinR = sin(r)
                        let projW = abs(aabbW * cosR + aabbH * sinR)
                        let projH = abs(-aabbW * sinR + aabbH * cosR)
                        rawSize = CGSize(width: projW, height: projH)
                    } else {
                        rawSize = CGSize(width: aabbW, height: aabbH)
                    }
                }
            }
            sourcePixelSize = rawSize
        } else {
            sourcePixelSize = nil
        }

        // Phase 0: Instant — check retina cache, then display preview cache, then thumbnail
        if let cached = imageCache.cachedImage(for: url) {
            imageLogger.info("\(filename): Phase 0 cache hit")
            currentImage = makeLoadedImage(from: cached)
            isLoading = false
            triggerPrefetch(for: url)
            return
        }

        if let displayPreview = imageCache.cachedDisplayPreview(for: url) {
            imageLogger.info("\(filename): Phase 0 display preview cache hit")
            currentImage = makeLoadedImage(from: displayPreview)
            isLoading = false
            // Skip Phase 0.5, go directly to Phase 2 for retina upgrade
            let screenScale = NSScreen.main?.backingScaleFactor ?? 2.0
            let screenLogicalPx = max(NSScreen.main?.frame.width ?? 3840, NSScreen.main?.frame.height ?? 2160)
            let screenMaxPx = screenLogicalPx * screenScale
            let fullStart = CFAbsoluteTimeGetCurrent()
            fullLoadTask = Task.detached(priority: .medium) {
                var image: CGImage?
                if cameraRaw != nil {
                    // HDR-preserving path: same decoder as EditWorkspaceView
                    if let ciImage = FullScreenImageCache.loadHDRPreview(from: url, maxPixelSize: screenMaxPx) {
                        image = Self.applyCameraRaw(to: ciImage, settings: cameraRaw, exifOrientation: imageOrientation)
                    }
                }
                if image == nil {
                    guard var loaded = FullScreenImageCache.loadDownsampled(from: url, maxPixelSize: screenMaxPx) else {
                        return
                    }
                    loaded = Self.applyCameraRaw(to: loaded, settings: cameraRaw, exifOrientation: imageOrientation)
                    image = loaded
                }
                guard let image, !Task.isCancelled else { return }
                let fullElapsed = CFAbsoluteTimeGetCurrent() - fullStart
                await MainActor.run {
                    if currentImageFile?.url == url {
                        imageLogger.info("\(filename): Phase 2 done in \(String(format: "%.1f", fullElapsed * 1000))ms (\(image.width)x\(image.height))")
                        currentImage = makeLoadedImage(from: image)
                        imageCache.store(image, for: url)
                        triggerPrefetch(for: url)
                    }
                }
            }
            return
        }

        // Cache miss — show thumbnail instantly (zero I/O) to avoid blank screen
        if let thumb = viewModel.thumbnailService.thumbnail(for: url),
           let thumbImage = makeLoadedImage(from: thumb) {
            imageLogger.info("\(filename): Phase 0 thumbnail placeholder")
            currentImage = thumbImage
        }

        isLoading = true

        let isRAW = SupportedImageFormats.isRaw(url: url)
        let screenScale = NSScreen.main?.backingScaleFactor ?? 2.0
        let screenLogicalPx = max(NSScreen.main?.frame.width ?? 3840, NSScreen.main?.frame.height ?? 2160)
        let screenMaxPx = screenLogicalPx * screenScale
        imageLogger.info("\(filename): isRAW=\(isRAW)")

        // Phase 0.5: Quick 960px preview (<5ms non-RAW)
        let previewStart = CFAbsoluteTimeGetCurrent()
        let preview: CGImage?
        if isRAW {
            // RAW: extract embedded JPEG preview (already small, ~1-3MP)
            preview = await Task.detached(priority: .medium) {
                guard let raw = FullScreenImageCache.extractEmbeddedPreview(from: url) else { return nil as CGImage? }
                return Self.applyCameraRaw(to: raw, settings: cameraRaw, exifOrientation: imageOrientation)
            }.value
        } else if cameraRaw != nil {
            // HDR-preserving path: same decoder as EditWorkspaceView for consistent rendering
            preview = await Task.detached(priority: .medium) {
                if let ciImage = FullScreenImageCache.loadHDRPreview(from: url, maxPixelSize: 960) {
                    return Self.applyCameraRaw(to: ciImage, settings: cameraRaw, exifOrientation: imageOrientation)
                }
                guard let raw = FullScreenImageCache.loadDownsampled(from: url, maxPixelSize: 960) else { return nil as CGImage? }
                return Self.applyCameraRaw(to: raw, settings: cameraRaw, exifOrientation: imageOrientation)
            }.value
        } else {
            // Non-RAW, no edits: quick downsample at 960px
            preview = await Task.detached(priority: .medium) {
                guard let raw = FullScreenImageCache.loadDownsampled(from: url, maxPixelSize: 960) else { return nil as CGImage? }
                return Self.applyCameraRaw(to: raw, settings: cameraRaw, exifOrientation: imageOrientation)
            }.value
        }
        let previewElapsed = CFAbsoluteTimeGetCurrent() - previewStart
        guard !Task.isCancelled else { return }
        if let preview, currentImageFile?.url == url {
            imageLogger.info("\(filename): Phase 0.5 in \(String(format: "%.1f", previewElapsed * 1000))ms (\(preview.width)x\(preview.height))")
            currentImage = makeLoadedImage(from: preview)
            imageCache.storeDisplayPreview(preview, for: url)
        }

        // Phase 2: Retina-resolution decode (screen pixels, preserving HDR color space)
        let fullStart = CFAbsoluteTimeGetCurrent()
        imageLogger.info("\(filename): Phase 2 starting (retina resolution)")
        fullLoadTask = Task.detached(priority: .medium) {
            var image: CGImage?
            if cameraRaw != nil {
                // HDR-preserving path: same decoder as EditWorkspaceView
                if let ciImage = FullScreenImageCache.loadHDRPreview(from: url, maxPixelSize: screenMaxPx) {
                    image = Self.applyCameraRaw(to: ciImage, settings: cameraRaw, exifOrientation: imageOrientation)
                }
            }
            if image == nil {
                guard var loaded = FullScreenImageCache.loadDownsampled(from: url, maxPixelSize: screenMaxPx) else {
                    imageLogger.error("\(filename): Phase 2 failed — could not decode image")
                    await MainActor.run {
                        if currentImageFile?.url == url {
                            isLoading = false
                            loadError = "Unable to load image"
                        }
                    }
                    return
                }
                loaded = Self.applyCameraRaw(to: loaded, settings: cameraRaw, exifOrientation: imageOrientation)
                image = loaded
            }
            guard let image else { return }
            let fullElapsed = CFAbsoluteTimeGetCurrent() - fullStart
            guard !Task.isCancelled else {
                imageLogger.info("\(filename): Phase 2 cancelled after \(String(format: "%.1f", fullElapsed * 1000))ms")
                return
            }
            await MainActor.run {
                if currentImageFile?.url == url {
                    imageLogger.info("\(filename): Phase 2 done in \(String(format: "%.1f", fullElapsed * 1000))ms (\(image.width)x\(image.height))")
                    currentImage = makeLoadedImage(from: image)
                    isLoading = false
                    loadError = nil
                    imageCache.store(image, for: url)
                    triggerPrefetch(for: url)
                } else {
                    imageLogger.info("\(filename): Phase 2 done but image changed, discarding")
                }
            }
        }
    }

    /// Lazily loads full source resolution when the user zooms past 100%.
    /// This avoids decoding massive images during normal navigation.
    private func loadFullResIfNeeded() {
        guard !isFullResLoaded else { return }
        let zoom100 = calculateZoomTo100()
        guard zoom100 < 1.0, zoomScale >= zoom100 * 0.9 else { return } // only needed for images larger than screen
        // Actually: we need full res when zoomed past the point where retina pixels run out.
        // At zoomScale=1.0, we have screenMaxPx worth of pixels. We need more when zoomScale > 1.0
        // and the image has more source pixels than screenMaxPx.
        guard zoomScale > 1.0 else { return }
        guard let url = currentImageFile?.url else { return }
        guard fullResTask == nil else { return }

        let filename = url.lastPathComponent
        let cameraRaw = renderEdits ? currentImageFile?.cameraRawSettings : nil
        let orientation = currentImageFile?.exifOrientation ?? 1
        imageLogger.info("\(filename): Loading full resolution for zoom")
        isLoading = true
        fullResTask = Task.detached(priority: .medium) {
            let fullStart = CFAbsoluteTimeGetCurrent()
            var image: CGImage?
            if cameraRaw != nil {
                // HDR-preserving path: same decoder as EditWorkspaceView
                if let ciImage = FullScreenImageCache.loadHDRFullResolution(from: url) {
                    image = Self.applyCameraRaw(to: ciImage, settings: cameraRaw, exifOrientation: orientation)
                }
            }
            if image == nil {
                guard var loaded = FullScreenImageCache.loadFullResolution(from: url) else { return }
                loaded = Self.applyCameraRaw(to: loaded, settings: cameraRaw, exifOrientation: orientation)
                image = loaded
            }
            guard let image else { return }
            let elapsed = CFAbsoluteTimeGetCurrent() - fullStart
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard currentImageFile?.url == url else { return }
                imageLogger.info("\(filename): Full resolution loaded in \(String(format: "%.1f", elapsed * 1000))ms (\(image.width)x\(image.height))")
                currentImage = makeLoadedImage(from: image)
                isFullResLoaded = true
                isLoading = false
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
        let visibleImages = viewModel.visibleImages
        let imageURLs = visibleImages.map(\.url)

        // Build lookups of CameraRaw settings and orientation for prefetch processing
        let settingsLookup: [URL: CameraRawSettings] = {
            var dict: [URL: CameraRawSettings] = [:]
            for image in visibleImages {
                if let settings = image.cameraRawSettings {
                    dict[image.url] = settings
                }
            }
            return dict
        }()
        let orientationLookup: [URL: Int] = {
            var dict: [URL: Int] = [:]
            for image in visibleImages {
                dict[image.url] = image.exifOrientation
            }
            return dict
        }()

        if renderEdits {
            imageCache.startPrefetch(
                currentIndex: currentIndex,
                images: imageURLs,
                direction: direction,
                screenMaxPx: screenMaxPx,
                settingsForURL: { url in settingsLookup[url] },
                orientationForURL: { url in orientationLookup[url] ?? 1 }
            )
        } else {
            imageCache.startPrefetch(
                currentIndex: currentIndex,
                images: imageURLs,
                direction: direction,
                screenMaxPx: screenMaxPx,
                orientationForURL: { url in orientationLookup[url] ?? 1 }
            )
        }
    }

    private func makeLoadedImage(from cgImage: CGImage) -> LoadedImage {
        LoadedImage(cgImage: cgImage, size: CGSize(width: cgImage.width, height: cgImage.height))
    }

    private func makeLoadedImage(from nsImage: NSImage) -> LoadedImage? {
        guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return makeLoadedImage(from: cgImage)
    }

    private static func rotateCGImage90(_ image: CGImage, clockwise: Bool) -> CGImage? {
        let width = image.width
        let height = image.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: nil,
            width: height,
            height: width,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        if clockwise {
            context.translateBy(x: 0, y: CGFloat(width))
            context.rotate(by: -.pi / 2)
        } else {
            context.translateBy(x: CGFloat(height), y: 0)
            context.rotate(by: .pi / 2)
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    // MARK: - Face Rectangles Overlay

    /// Generate a distinct color for a face group based on its UUID
    private func colorForGroup(_ groupID: UUID?) -> Color {
        guard let groupID else { return Color.gray }
        let hue = Double(groupID.uuid.0 ^ groupID.uuid.1) / 256.0
        return Color(hue: hue, saturation: 0.8, brightness: 0.9)
    }

    /// Calculate where the image content is displayed within a container using aspect-fit
    private func calculateImageDisplayRect(imageSize: CGSize, in containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else {
            return .zero
        }
        let imageAspect = imageSize.width / imageSize.height
        let containerAspect = containerSize.width / containerSize.height
        if imageAspect > containerAspect {
            let displayHeight = containerSize.width / imageAspect
            let yOffset = (containerSize.height - displayHeight) / 2
            return CGRect(x: 0, y: yOffset, width: containerSize.width, height: displayHeight)
        } else {
            let displayWidth = containerSize.height * imageAspect
            let xOffset = (containerSize.width - displayWidth) / 2
            return CGRect(x: xOffset, y: 0, width: displayWidth, height: containerSize.height)
        }
    }

    /// Convert Vision face rect (normalized, bottom-left origin) to display rect (pixels, top-left origin)
    private func convertFaceRect(_ faceRect: CGRect, toDisplayIn imageDisplayRect: CGRect) -> CGRect {
        let displayX = imageDisplayRect.minX + faceRect.origin.x * imageDisplayRect.width
        let displayY = imageDisplayRect.minY + (1.0 - faceRect.origin.y - faceRect.height) * imageDisplayRect.height
        let displayW = faceRect.width * imageDisplayRect.width
        let displayH = faceRect.height * imageDisplayRect.height
        return CGRect(x: displayX, y: displayY, width: displayW, height: displayH)
    }

    @ViewBuilder
    private func faceRectanglesOverlay(imageSize: CGSize, containerSize: CGSize) -> some View {
        let faceContext = viewModel.fullScreenFaceContext
        let highlightedFaceID = faceContext?.highlightedFaceID
        let imageDisplayRect = calculateImageDisplayRect(imageSize: imageSize, in: containerSize)

        if let faceVM = faceContext?.faceRecognitionViewModel,
           let url = currentImageFile?.url {
            let facesInImage = faceVM.facesForImage(url)
            Canvas { context, _ in
                for face in facesInImage {
                    let isHighlighted = face.id == highlightedFaceID
                    let faceDisplayRect = convertFaceRect(face.faceRect, toDisplayIn: imageDisplayRect)
                    let groupColor = colorForGroup(face.groupID)
                    let lineWidth: CGFloat = isHighlighted ? 4 : 2
                    let opacity: CGFloat = isHighlighted ? 1.0 : 0.5
                    let path = Path(roundedRect: faceDisplayRect, cornerRadius: 4)
                    context.stroke(path, with: .color(groupColor.opacity(opacity)), lineWidth: lineWidth)
                }
            }
            .allowsHitTesting(false)
        }
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
    @State private var resignObserver: Any?

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
        window.onToggleZoom = { [weak controller] location in
            controller?.toggleZoom(at: location)
        }
        window.onScrollZoom = { [weak controller] delta, location in
            controller?.scrollZoom(delta, at: location)
        }
        window.onToggleUI = { [weak controller] in
            controller?.toggleUI()
        }
        window.onToggleScaling = { [weak controller] in
            controller?.toggleScaling()
        }
        window.onToggleFaceRectangles = { [weak controller] in
            controller?.toggleFaceRectangles()
        }
        window.onToggleEditRendering = { [weak controller] in
            controller?.toggleEditRendering()
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

        // Close full screen when app loses focus (Cmd+Tab, clicking another app)
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak viewModel] _ in
            Task { @MainActor [weak viewModel] in
                viewModel?.isFullScreen = false
            }
        }
    }

    private func closeFullScreen() {
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
        resignObserver = nil
        fullScreenWindow?.orderOut(nil)
        fullScreenWindow = nil
        zoomController = nil
        viewModel.fullScreenFaceContext = nil
    }
}

extension View {
    func fullScreenImagePresenter(viewModel: BrowserViewModel) -> some View {
        modifier(FullScreenPresenter(viewModel: viewModel))
    }
}
