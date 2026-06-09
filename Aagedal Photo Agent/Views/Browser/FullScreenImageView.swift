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
        if keyCode == 6 && !hasCmd && !hasOption && !event.isARepeat {
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
        if keyCode == 4 && !hasCmd && !hasOption && !event.isARepeat {
            onToggleUI?()
            return
        }

        // Option+S (keyCode 1) → toggle scaling filter.
        // Bare S is reserved for "select" cull shortcut below.
        if keyCode == 1 && !hasCmd && hasOption && !event.isARepeat {
            onToggleScaling?()
            return
        }

        // F key (keyCode 3) → toggle face rectangles
        if keyCode == 3 && !hasCmd && !hasOption && !event.isARepeat {
            onToggleFaceRectangles?()
            return
        }

        // E key (keyCode 14) → toggle edit rendering
        if keyCode == 14 && !hasCmd && !hasOption && !event.isARepeat {
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
        } else if !hasOption {
            // Bare-digit shortcuts (PhotoMechanic muscle memory).
            // 0-5 → rating, 6-9 → color label slot 1-4.
            if let n = numberKeyCodes[keyCode] {
                if n <= 5 {
                    onSetRating?(n)
                    return
                }
                if (6...9).contains(n) {
                    onSetLabel?(n - 5)
                    return
                }
            }
            // X (keyCode 7) → trash label, S (keyCode 1) → red/select.
            if keyCode == 7 && !event.isARepeat {
                onSetLabel?(8) // ColorLabel.trash → shortcutIndex 8
                return
            }
            if keyCode == 1 && !event.isARepeat {
                onSetLabel?(1) // ColorLabel.red → shortcutIndex 1
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
    let scopeViewModel: ScopeViewModel
    fileprivate var zoomController: ZoomController?

    @State private var currentImage: LoadedImage?
    @State private var originalCGImage: CGImage?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var fullLoadTask: Task<Void, Never>?
    @State private var phase05Task: Task<CGImage?, Never>?
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
    @State private var renderGeneration: Int = 0
    @State private var settingsReloadTask: Task<Void, Never>?

    // Face overlay state
    @State private var showFaceRectangles: Bool = false

    // Zoom state
    @State private var zoomScale: CGFloat = 1.0
    @State private var lastZoomScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var isZoomedTo100: Bool = false
    @State private var sourcePixelSize: CGSize?
    /// Shared linear/nearest-neighbor scaling toggle (View menu + Option+S).
    @ObservedObject private var scaling = ImageScalingController.shared
    @State private var lastOrientationURL: URL?
    @State private var lastLoadedOrientation: Int = 1

    /// Minimum zoom allows zooming out to 1:1 pixel mapping for small images.
    private var minZoom: CGFloat {
        min(calculateZoomTo100(), 1.0)
    }
    private let maxZoom: CGFloat = 40.0

    private var currentImageFile: ImageFile? {
        viewModel.firstSelectedImage
    }

    private var isHDR: Bool {
        currentImageFile?.isNativeHDR == true
            || (renderEdits && currentImageFile?.cameraRawSettings?.hdrEditMode == 1)
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
                    HDRImageView(cgImage: currentImage.cgImage, isHDR: isHDR, useNearestNeighbor: scaling.useNearestNeighbor)
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
                        VStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                            Text("Loading\u{2026}")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .padding(12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
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
                            || file.hasPendingMetadataChanges || file.isNativeHDR || file.cameraRawSettings?.hdrEditMode == 1 {
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
                                        if file.isNativeHDR || file.cameraRawSettings?.hdrEditMode == 1 {
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

                                if scaling.useNearestNeighbor {
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
            // Full screen always starts with originals; press E to toggle edits
            renderEdits = false
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
                scaling.toggle()
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
            let urlChanged = currentImageFile?.url != lastOrientationURL
            if urlChanged {
                // Reset zoom/pan only when navigating to a different image
                zoomScale = 1.0
                lastZoomScale = 1.0
                offset = .zero
                lastOffset = .zero
                isZoomedTo100 = false
            }
            isFullResLoaded = false
            fullResTask?.cancel()
            fullResTask = nil
            phase05Task?.cancel()
            phase05Task = nil
            lastOrientationURL = currentImageFile?.url
            await loadImage()
        }
        .onChange(of: renderEdits) {
            // Cancel stale prefetch (targets may be wrong for the new mode) but
            // keep both caches intact so switching back is instant.
            imageCache.cancelAllPrefetch()
            // Show loading overlay immediately so the user has feedback
            // while the new version loads. The old image stays visible as
            // a placeholder underneath — the .task will replace it.
            isLoading = true
        }
        .onChange(of: currentImageFile?.cameraRawSettings) {
            // Invalidate cached image when edits change (e.g. mask adjustments
            // committed in edit workspace) so the full-screen preview re-renders
            guard renderEdits, let url = currentImageFile?.url else { return }
            imageCache.invalidateImage(for: url)
            currentImage = nil
            settingsReloadTask?.cancel()
            settingsReloadTask = Task { await loadImage() }
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
            // If the image was already decoded with this orientation (e.g. metadata
            // batch read catching up), the pixels are already correct — skip.
            guard newValue != lastLoadedOrientation else { return }
            let clockwise = ImageFile.orientationAfterClockwiseRotation(oldValue) == newValue
            if let rotated = Self.rotateCGImage90(current.cgImage, clockwise: clockwise) {
                currentImage = makeLoadedImage(from: rotated)
            }
            imageCache.invalidateImage(for: url)
        }
        .onChange(of: scopeViewModel.showClippedGamut) {
            guard let original = originalCGImage else { return }
            let image = scopeViewModel.showClippedGamut
                ? Self.gamutClipped(original, targetGamut: scopeViewModel.targetGamut)
                : original
            currentImage = LoadedImage(cgImage: image, size: CGSize(width: original.width, height: original.height))
        }
        .onChange(of: scopeViewModel.targetGamut) {
            guard scopeViewModel.showClippedGamut, let original = originalCGImage else { return }
            let image = Self.gamutClipped(original, targetGamut: scopeViewModel.targetGamut)
            currentImage = LoadedImage(cgImage: image, size: CGSize(width: original.width, height: original.height))
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
    /// When `fileOrientation` differs from `exifOrientation`, the image pixels have
    /// the file's orientation baked in (e.g. C2PA images where the file wasn't modified).
    /// Crop uses `fileOrientation` to match the pixel layout, then a corrective rotation
    /// is applied to reach the target `exifOrientation`.
    nonisolated private static func applyCameraRaw(to cgImage: CGImage, settings: CameraRawSettings?, exifOrientation: Int = 1, fileOrientation: Int = 0) -> CGImage {
        guard let settings else {
            return applyOrientationCorrection(cgImage, fileOrientation: fileOrientation, targetOrientation: exifOrientation)
        }
        let cropOrientation = fileOrientation > 0 ? fileOrientation : exifOrientation
        let ciImage = CIImage(cgImage: cgImage)
        var processed = CameraRawApproximation.applyWithCrop(to: ciImage, settings: settings, exifOrientation: cropOrientation)

        let correction = ImageFile.orientationCorrection(from: cropOrientation, to: exifOrientation)
        if correction != .up { processed = processed.oriented(correction) }

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

    /// Apply gamut clipping to a CGImage by rendering through a target color space CGContext.
    nonisolated private static func gamutClipped(_ cgImage: CGImage, targetGamut: TargetColorGamut) -> CGImage {
        let targetCS: CGColorSpace
        switch targetGamut {
        case .sRGB:      targetCS = CGColorSpace(name: CGColorSpace.sRGB)!
        case .displayP3: targetCS = CGColorSpace(name: CGColorSpace.displayP3)!
        case .rec2020:   targetCS = CGColorSpace(name: CGColorSpace.itur_2020)!
        case .adobeRGB:  targetCS = CGColorSpace(name: CGColorSpace.adobeRGB1998)!
        }
        let w = cgImage.width, h = cgImage.height
        // Draw into target gamut (clips out-of-gamut values)
        guard let clipCtx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: targetCS,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return cgImage }
        clipCtx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let clipped = clipCtx.makeImage() else { return cgImage }
        // Convert back to extended linear sRGB for HDR-aware display
        let bitmapInfo = CGBitmapInfo.floatComponents.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let finalCtx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 32, bytesPerRow: w * 16,
            space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            bitmapInfo: bitmapInfo
        ) else { return clipped }
        finalCtx.draw(clipped, in: CGRect(x: 0, y: 0, width: w, height: h))
        return finalCtx.makeImage() ?? clipped
    }

    /// Apply CameraRaw adjustments + crop to a CIImage source, preserving HDR float values.
    nonisolated private static func applyCameraRaw(to ciImage: CIImage, settings: CameraRawSettings?, exifOrientation: Int = 1, fileOrientation: Int = 0) -> CGImage? {
        let cropOrientation = fileOrientation > 0 ? fileOrientation : exifOrientation
        var processed: CIImage
        if let settings {
            processed = CameraRawApproximation.applyWithCrop(to: ciImage, settings: settings, exifOrientation: cropOrientation)
        } else {
            processed = ciImage
        }

        let correction = ImageFile.orientationCorrection(from: cropOrientation, to: exifOrientation)
        if correction != .up { processed = processed.oriented(correction) }

        let extent = processed.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        return CameraRawApproximation.ciContext.createCGImage(
            processed, from: extent,
            format: .RGBAh,
            colorSpace: CameraRawApproximation.workingColorSpace
        )
    }

    /// Correct a CGImage's orientation when the file's baked-in orientation
    /// differs from the target (in-memory) orientation.
    nonisolated private static func applyOrientationCorrection(
        _ cgImage: CGImage,
        fileOrientation: Int,
        targetOrientation: Int
    ) -> CGImage {
        let delta = ImageFile.rotationDelta(from: fileOrientation > 0 ? fileOrientation : targetOrientation, to: targetOrientation)
        guard delta > 0 else { return cgImage }
        var result = cgImage
        switch delta {
        case 1: result = rotateCGImage90(result, clockwise: true) ?? result
        case 2:
            result = rotateCGImage90(result, clockwise: true) ?? result
            result = rotateCGImage90(result, clockwise: true) ?? result
        case 3: result = rotateCGImage90(result, clockwise: false) ?? result
        default: break
        }
        return result
    }

    private func loadImage() async {
        let filename = currentImageFile?.url.lastPathComponent ?? "nil"
        imageLogger.info("loadImage called for \(filename)")

        // Guarantee isLoading is cleared when loadImage returns, regardless of
        // exit path (cache hit, cancellation, Phase 0.5 completion).
        // Phase 2 runs as a detached background task and does NOT need to manage isLoading.
        defer { isLoading = false }

        // Bump generation so any in-flight Phase 2 detached tasks discard their results
        renderGeneration += 1
        let expectedGeneration = renderGeneration

        // Cancel any in-flight loads from the previous image / render mode
        if fullLoadTask != nil {
            imageLogger.info("Cancelling previous full-resolution load")
        }
        fullLoadTask?.cancel()
        fullLoadTask = nil
        phase05Task?.cancel()
        phase05Task = nil

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

        let isEdited = renderEdits
        let cameraRaw = renderEdits ? currentImageFile?.cameraRawSettings : nil
        let isNativeHDR = currentImageFile?.isNativeHDR == true
        let needsHDRLoad = cameraRaw != nil || isNativeHDR
        let maskCount = cameraRaw?.localAdjustments?.count ?? 0
        let enabledMaskCount = cameraRaw?.localAdjustments?.filter(\.enabled).count ?? 0
        imageLogger.info("\(filename): renderEdits=\(renderEdits), cameraRaw=\(cameraRaw != nil), nativeHDR=\(isNativeHDR), masks=\(maskCount) (enabled=\(enabledMaskCount)), exp=\(cameraRaw?.exposure2012 ?? 0)")
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
                // The stored region is the upright crop rectangle — its dimensions are the
                // actual (straightened) crop output dimensions directly.
                let cropW = ((displayCrop.right ?? 1) - (displayCrop.left ?? 0)) * rawSize.width
                let cropH = ((displayCrop.bottom ?? 1) - (displayCrop.top ?? 0)) * rawSize.height
                if cropW > 1, cropH > 1 {
                    rawSize = CGSize(width: cropW, height: cropH)
                }
            }
            sourcePixelSize = rawSize
            lastLoadedOrientation = orientation
        } else {
            sourcePixelSize = nil
            lastLoadedOrientation = imageOrientation
        }

        // File orientation = what the OS baked into the loaded pixels.
        // When it differs from imageOrientation (e.g. C2PA images where
        // the file isn't modified), applyCameraRaw applies corrective rotation.
        let fileOrientation = lastLoadedOrientation

        // An in-flight prefetch decodes at the same resolution/edit-state as the
        // foreground load, so reuse it instead of decoding twice during fast
        // navigation. The prefetch path omits the fileOrientation corrective
        // rotation, so only reuse it when that correction is a no-op.
        let canReusePrefetch = fileOrientation == imageOrientation
        let cache = imageCache

        // If corrective rotation swaps width/height, adjust sourcePixelSize
        let delta = ImageFile.rotationDelta(from: fileOrientation, to: imageOrientation)
        if (delta == 1 || delta == 3), let size = sourcePixelSize {
            sourcePixelSize = CGSize(width: size.height, height: size.width)
        }

        // Phase 0: Instant — check retina cache, then display preview cache, then thumbnail
        if let cached = imageCache.cachedImage(for: url, isEdited: isEdited) {
            imageLogger.info("\(filename): Phase 0 cache hit (edited=\(isEdited))")
            currentImage = makeLoadedImage(from: cached)
            isLoading = false
            triggerPrefetch(for: url)
            return
        }

        if let displayPreview = imageCache.cachedDisplayPreview(for: url, isEdited: isEdited) {
            imageLogger.info("\(filename): Phase 0 display preview cache hit (edited=\(isEdited))")
            currentImage = makeLoadedImage(from: displayPreview)
            isLoading = false
            // Skip Phase 0.5, go directly to Phase 2 for retina upgrade
            let screenScale = NSScreen.main?.backingScaleFactor ?? 2.0
            let screenLogicalPx = max(NSScreen.main?.frame.width ?? 3840, NSScreen.main?.frame.height ?? 2160)
            let screenMaxPx = screenLogicalPx * screenScale
            let isRAWFile = SupportedImageFormats.isRaw(url: url)
            let fullStart = CFAbsoluteTimeGetCurrent()
            fullLoadTask = Task.detached(priority: .medium) {
                guard !Task.isCancelled else { return }
                // Reuse an in-flight prefetch decode rather than decoding this exact
                // image a second time concurrently (fast navigation).
                var image: CGImage? = canReusePrefetch
                    ? await cache.awaitPrefetchedImage(for: url, isEdited: isEdited)
                    : nil
                if image == nil, needsHDRLoad {
                    if isRAWFile {
                        // Use CIRAWFilter for flat/neutral decode — get as-shot WB for correct rendering
                        if let rawResult = FullScreenImageCache.loadRAWImage(from: url, draftMode: false, isHDR: cameraRaw?.hdrEditMode == 1 || isNativeHDR) {
                            guard !Task.isCancelled else { return }
                            var settings = cameraRaw
                            settings?.asShotNeutralTemperature = Double(rawResult.neutralTemperature)
                            settings?.asShotNeutralTint = Double(rawResult.neutralTint)
                            let ciImage = FullScreenImageCache.downsample(rawResult.image, maxPixelSize: screenMaxPx)
                            image = Self.applyCameraRaw(to: ciImage, settings: settings, exifOrientation: imageOrientation, fileOrientation: fileOrientation)
                        }
                    } else {
                        if let ciImage = FullScreenImageCache.loadHDRPreview(from: url, maxPixelSize: screenMaxPx) {
                            guard !Task.isCancelled else { return }
                            image = Self.applyCameraRaw(to: ciImage, settings: cameraRaw, exifOrientation: imageOrientation, fileOrientation: fileOrientation)
                        }
                    }
                }
                guard !Task.isCancelled else { return }
                if image == nil {
                    guard var loaded = FullScreenImageCache.loadDownsampled(from: url, maxPixelSize: screenMaxPx) else {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    loaded = Self.applyCameraRaw(to: loaded, settings: cameraRaw, exifOrientation: imageOrientation, fileOrientation: fileOrientation)
                    image = loaded
                }
                guard let image, !Task.isCancelled else { return }
                let fullElapsed = CFAbsoluteTimeGetCurrent() - fullStart
                await MainActor.run {
                    guard expectedGeneration == renderGeneration,
                          currentImageFile?.url == url else { return }
                    imageLogger.info("\(filename): Phase 2 done in \(String(format: "%.1f", fullElapsed * 1000))ms (\(image.width)x\(image.height))")
                    currentImage = makeLoadedImage(from: image)
                    lastLoadedOrientation = imageOrientation
                    imageCache.store(image, for: url, isEdited: isEdited)
                    triggerPrefetch(for: url)
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

        // Launch Phase 2 immediately (fire-and-forget) so it runs in parallel with Phase 0.5.
        // Phase 0.5 provides a quick preview; Phase 2 replaces it with retina resolution.
        let fullStart = CFAbsoluteTimeGetCurrent()
        imageLogger.info("\(filename): Phase 2 starting (retina resolution, parallel with Phase 0.5)")
        fullLoadTask = Task.detached(priority: .medium) {
            guard !Task.isCancelled else { return }
            // Reuse an in-flight prefetch decode rather than decoding this exact
            // image a second time concurrently (fast navigation).
            var image: CGImage? = canReusePrefetch
                ? await cache.awaitPrefetchedImage(for: url, isEdited: isEdited)
                : nil
            if image == nil, needsHDRLoad {
                if isRAW {
                    // Use CIRAWFilter for flat/neutral decode — get as-shot WB for correct rendering
                    if let rawResult = FullScreenImageCache.loadRAWImage(from: url, draftMode: false, isHDR: cameraRaw?.hdrEditMode == 1 || isNativeHDR) {
                        guard !Task.isCancelled else { return }
                        var settings = cameraRaw
                        settings?.asShotNeutralTemperature = Double(rawResult.neutralTemperature)
                        settings?.asShotNeutralTint = Double(rawResult.neutralTint)
                        let ciImage = FullScreenImageCache.downsample(rawResult.image, maxPixelSize: screenMaxPx)
                        image = Self.applyCameraRaw(to: ciImage, settings: settings, exifOrientation: imageOrientation, fileOrientation: fileOrientation)
                    }
                } else {
                    if let ciImage = FullScreenImageCache.loadHDRPreview(from: url, maxPixelSize: screenMaxPx) {
                        guard !Task.isCancelled else { return }
                        image = Self.applyCameraRaw(to: ciImage, settings: cameraRaw, exifOrientation: imageOrientation, fileOrientation: fileOrientation)
                    }
                }
            }
            guard !Task.isCancelled else { return }
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
                guard !Task.isCancelled else { return }
                loaded = Self.applyCameraRaw(to: loaded, settings: cameraRaw, exifOrientation: imageOrientation, fileOrientation: fileOrientation)
                image = loaded
            }
            guard let image else { return }
            let fullElapsed = CFAbsoluteTimeGetCurrent() - fullStart
            guard !Task.isCancelled else {
                imageLogger.info("\(filename): Phase 2 cancelled after \(String(format: "%.1f", fullElapsed * 1000))ms")
                return
            }
            await MainActor.run {
                guard expectedGeneration == renderGeneration else {
                    imageLogger.info("\(filename): Phase 2 done but generation stale, discarding")
                    return
                }
                if currentImageFile?.url == url {
                    imageLogger.info("\(filename): Phase 2 done in \(String(format: "%.1f", fullElapsed * 1000))ms (\(image.width)x\(image.height))")
                    currentImage = makeLoadedImage(from: image)
                    lastLoadedOrientation = imageOrientation
                    isLoading = false
                    loadError = nil
                    imageCache.store(image, for: url, isEdited: isEdited)
                    triggerPrefetch(for: url)
                } else {
                    imageLogger.info("\(filename): Phase 2 done but image changed, discarding")
                }
            }
        }

        // Phase 0.5: Quick 960px preview (<5ms non-RAW) — runs in parallel with Phase 2.
        // Stored so it can be cancelled when the user toggles edit mode or navigates,
        // preventing orphaned tasks from exhausting the cooperative thread pool.
        let previewStart = CFAbsoluteTimeGetCurrent()
        let p05 = Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard !Task.isCancelled else { return nil }
            if isRAW {
                guard let raw = FullScreenImageCache.extractEmbeddedPreview(from: url) else { return nil }
                guard !Task.isCancelled else { return nil }
                return Self.applyCameraRaw(to: raw, settings: cameraRaw, exifOrientation: imageOrientation, fileOrientation: fileOrientation)
            }
            // Try HDR CIImage path first; fall through to CGImage if crop/render fails
            if needsHDRLoad,
               let ciImage = FullScreenImageCache.loadHDRPreview(from: url, maxPixelSize: 960) {
                guard !Task.isCancelled else { return nil }
                if let result = Self.applyCameraRaw(to: ciImage, settings: cameraRaw, exifOrientation: imageOrientation, fileOrientation: fileOrientation) {
                    return result
                }
            }
            // CGImage fallback — applyCameraRaw(to: CGImage) always returns a valid image
            guard !Task.isCancelled else { return nil }
            guard let raw = FullScreenImageCache.loadDownsampled(from: url, maxPixelSize: 960) else { return nil }
            guard !Task.isCancelled else { return nil }
            return Self.applyCameraRaw(to: raw, settings: cameraRaw, exifOrientation: imageOrientation, fileOrientation: fileOrientation)
        }
        phase05Task = p05
        let preview = await p05.value
        let previewElapsed = CFAbsoluteTimeGetCurrent() - previewStart
        guard !Task.isCancelled else { return }
        if let preview, currentImageFile?.url == url {
            imageLogger.info("\(filename): Phase 0.5 in \(String(format: "%.1f", previewElapsed * 1000))ms (\(preview.width)x\(preview.height))")
            currentImage = makeLoadedImage(from: preview)
            imageCache.storeDisplayPreview(preview, for: url, isEdited: isEdited)
        }
        // defer { isLoading = false } at function entry handles clearing the loading overlay.
        // Phase 2 upgrades quality silently in the background.
    }

    /// Lazily loads full source resolution when the user zooms in far enough that
    /// the retina-resolution Phase 2 image runs out of detail.
    private func loadFullResIfNeeded() {
        guard !isFullResLoaded else { return }
        guard let url = currentImageFile?.url else { return }
        guard fullResTask == nil else { return }

        // Only needed when source has more pixels than the retina-resolution Phase 2 load.
        // Phase 2 uses loadDownsampled which only downsamples at 1.5x, so match that threshold.
        let screenScale = NSScreen.main?.backingScaleFactor ?? 2.0
        let screenLogicalPx = max(NSScreen.main?.frame.width ?? 3840, NSScreen.main?.frame.height ?? 2160)
        let screenMaxPx = screenLogicalPx * screenScale
        let sourceMax = max(sourcePixelSize?.width ?? 0, sourcePixelSize?.height ?? 0)
        guard sourceMax > screenMaxPx * 1.5 else { return }

        // Trigger when zooming in (retina pixels start running out)
        guard zoomScale > 1.0 else { return }

        let filename = url.lastPathComponent
        let cameraRaw = renderEdits ? currentImageFile?.cameraRawSettings : nil
        let needsHDRFullRes = cameraRaw != nil || currentImageFile?.isNativeHDR == true
        let isHDRDecode = cameraRaw?.hdrEditMode == 1 || currentImageFile?.isNativeHDR == true
        let isRAWFile = SupportedImageFormats.isRaw(url: url)
        let orientation = currentImageFile?.exifOrientation ?? 1
        let zoomFileOrientation = lastLoadedOrientation
        let expectedGeneration = renderGeneration
        imageLogger.info("\(filename): Loading full resolution for zoom")
        isLoading = true
        fullResTask = Task.detached(priority: .medium) {
            guard !Task.isCancelled else { return }
            let fullStart = CFAbsoluteTimeGetCurrent()
            var image: CGImage?
            if needsHDRFullRes {
                if isRAWFile {
                    // Use CIRAWFilter for flat/neutral full-res decode — get as-shot WB
                    if let rawResult = FullScreenImageCache.loadRAWImage(from: url, draftMode: false, isHDR: isHDRDecode) {
                        guard !Task.isCancelled else { return }
                        var settings = cameraRaw
                        settings?.asShotNeutralTemperature = Double(rawResult.neutralTemperature)
                        settings?.asShotNeutralTint = Double(rawResult.neutralTint)
                        image = Self.applyCameraRaw(to: rawResult.image, settings: settings, exifOrientation: orientation, fileOrientation: zoomFileOrientation)
                    }
                } else {
                    if let ciImage = FullScreenImageCache.loadHDRFullResolution(from: url) {
                        guard !Task.isCancelled else { return }
                        image = Self.applyCameraRaw(to: ciImage, settings: cameraRaw, exifOrientation: orientation, fileOrientation: zoomFileOrientation)
                    }
                }
            }
            guard !Task.isCancelled else { return }
            if image == nil {
                guard var loaded = FullScreenImageCache.loadFullResolution(from: url) else { return }
                guard !Task.isCancelled else { return }
                loaded = Self.applyCameraRaw(to: loaded, settings: cameraRaw, exifOrientation: orientation, fileOrientation: zoomFileOrientation)
                image = loaded
            }
            guard let image else { return }
            let elapsed = CFAbsoluteTimeGetCurrent() - fullStart
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard expectedGeneration == renderGeneration,
                      currentImageFile?.url == url else { return }
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
                isEdited: true,
                settingsForURL: { url in settingsLookup[url] },
                orientationForURL: { url in orientationLookup[url] ?? 1 }
            )
        } else {
            imageCache.startPrefetch(
                currentIndex: currentIndex,
                images: imageURLs,
                direction: direction,
                screenMaxPx: screenMaxPx,
                isEdited: false,
                orientationForURL: { url in orientationLookup[url] ?? 1 }
            )
        }
    }

    private func makeLoadedImage(from cgImage: CGImage) -> LoadedImage {
        originalCGImage = cgImage
        let image = scopeViewModel.showClippedGamut
            ? Self.gamutClipped(cgImage, targetGamut: scopeViewModel.targetGamut)
            : cgImage
        return LoadedImage(cgImage: image, size: CGSize(width: cgImage.width, height: cgImage.height))
    }

    private func makeLoadedImage(from nsImage: NSImage) -> LoadedImage? {
        guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return makeLoadedImage(from: cgImage)
    }

    nonisolated private static func rotateCGImage90(_ image: CGImage, clockwise: Bool) -> CGImage? {
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
    let scopeViewModel: ScopeViewModel
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
            rootView: FullScreenImageView(viewModel: viewModel, scopeViewModel: scopeViewModel, zoomController: controller)
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
    func fullScreenImagePresenter(viewModel: BrowserViewModel, scopeViewModel: ScopeViewModel) -> some View {
        modifier(FullScreenPresenter(viewModel: viewModel, scopeViewModel: scopeViewModel))
    }
}
