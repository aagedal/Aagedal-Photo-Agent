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

/// Presents the shared image-deletion confirmation from the window that is actually visible.
/// The full-screen viewer is a separate always-on-top window, so leaving this alert on the
/// browser window makes the app appear frozen when a menu shortcut triggers deletion.
private struct ImageDeletionConfirmationModifier: ViewModifier {
    @Bindable var viewModel: BrowserViewModel
    let isActiveHost: Bool

    private var isPresented: Binding<Bool> {
        Binding(
            get: { isActiveHost && viewModel.showDeleteConfirmation },
            set: { newValue in
                // An inactive window must not dismiss confirmation state owned by the
                // active window while SwiftUI updates the two presentation hosts.
                guard isActiveHost else { return }
                viewModel.showDeleteConfirmation = newValue
            }
        )
    }

    func body(content: Content) -> some View {
        content
            .alert("Move to Trash", isPresented: isPresented) {
                Button("Cancel", role: .cancel) { }
                Button("Move to Trash", role: .destructive) {
                    viewModel.deleteSelectedImages()
                }
            } message: {
                let count = viewModel.selectedImageIDs.count
                Text("Are you sure you want to move \(count) \(count == 1 ? "image" : "images") to the Trash?")
            }
    }
}

extension View {
    func imageDeletionConfirmation(
        viewModel: BrowserViewModel,
        isActiveHost: Bool
    ) -> some View {
        modifier(ImageDeletionConfirmationModifier(
            viewModel: viewModel,
            isActiveHost: isActiveHost
        ))
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
    var openComparisonAction: (() -> Void)?

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

    func openComparison() {
        openComparisonAction?()
    }
}

// MARK: - Full-screen keyboard shortcuts

enum FullScreenNumberShortcut: Equatable, Sendable {
    case rating(Int)
    case colorLabel(Int)

    private static let numberByKeyCode: [Int: Int] = [
        29: 0,
        18: 1,
        19: 2,
        20: 3,
        21: 4,
        23: 5,
        22: 6,
        26: 7,
        28: 8,
        25: 9,
    ]

    static func resolve(keyCode: Int, command: Bool, option: Bool) -> Self? {
        guard let number = numberByKeyCode[keyCode] else { return nil }

        if command && option {
            return number <= 8 ? .colorLabel(number) : nil
        }
        if command {
            return number <= 5 ? .rating(number) : nil
        }
        guard !option else { return nil }

        if number <= 5 {
            return .rating(number)
        }
        return .colorLabel(number - 5)
    }
}

// MARK: - Full-screen loading presentation

enum FullScreenLoadingGuidance {
    static let editedPreview = "Edited previews can take longer. Press E to turn off edits when faster high-resolution loading matters."

    static func message(isRenderingEdits: Bool, hasEdits: Bool) -> String? {
        guard isRenderingEdits, hasEdits else { return nil }
        return editedPreview
    }
}

struct FullScreenLoadFailure: Equatable, Sendable {
    let url: URL
    let isRenderingEdits: Bool

    var message: String {
        "Unable to load this image at high resolution."
    }

    var details: String {
        """
        Full-screen image load failed
        File: \(url.lastPathComponent)
        Path: \(url.path)
        Preview mode: \(isRenderingEdits ? "Edited" : "Original")
        """
    }
}

// MARK: - Custom NSWindow that intercepts Escape and Space

private class FullScreenWindow: NSWindow {
    var onDismiss: (() -> Void)?
    var onOpenComparison: (() -> Void)?
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

        // C → transition to Compare. Modified C remains available to system commands.
        if keyCode == 8 && !hasCmd && !hasOption && !event.isARepeat,
           let onOpenComparison {
            onOpenComparison()
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

        let inputState = keyboardTextInputState(in: self)
        if let key = event.charactersIgnoringModifiers?.first,
           let action = KeyboardShortcutRouter.resolve(
            KeyboardShortcutRouteInput(
                key: String(key),
                modifiers: KeyboardShortcutModifiers(flags),
                textEditorOwnsInput: inputState.textEditorOwnsInput,
                imeHasMarkedText: inputState.imeHasMarkedText,
                isRepeat: event.isARepeat
            ),
            profile: KeyboardShortcutProfileRegistry.shared.selectedProfile
           ) {
            switch action {
            case let .rating(value): onSetRating?(value)
            case let .colorLabel(index): onSetLabel?(index)
            }
            return
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
    let canOpenComparison: Bool
    let onRequestComparison: (Bool) -> Void
    fileprivate var zoomController: ZoomController?

    fileprivate init(
        viewModel: BrowserViewModel,
        scopeViewModel: ScopeViewModel,
        canOpenComparison: Bool = false,
        onRequestComparison: @escaping (Bool) -> Void = { _ in },
        zoomController: ZoomController? = nil
    ) {
        self.viewModel = viewModel
        self.scopeViewModel = scopeViewModel
        self.canOpenComparison = canOpenComparison
        self.onRequestComparison = onRequestComparison
        self.zoomController = zoomController
    }

    @State private var currentImage: LoadedImage?
    @State private var originalCGImage: CGImage?
    @State private var isLoading = false
    /// True while the zoom-triggered full-resolution decode is in flight. Drives
    /// the "Loading hires…" overlay, which is shown only while zoomed — the
    /// retina/preview background upgrades stay silent.
    @State private var isLoadingHires = false
    @State private var loadFailure: FullScreenLoadFailure?
    @State private var fullLoadTask: Task<Void, Never>?
    @State private var phase05Task: Task<CGImage?, Never>?
    @State private var fullResTask: Task<Void, Never>?
    @State private var isFullResLoaded = false
    /// Set once the retina Phase 2 decode has applied its result for the current
    /// load generation. Phase 0.5 (the quick low-res preview) runs concurrently
    /// and finishes its `await` after Phase 2 in some cases (cached/fast retina
    /// decode) — without this guard it would overwrite the sharp image with the
    /// 960px preview, leaving the view stuck on low-res.
    @State private var hiResApplied = false
    @State private var showLabelPicker = false
    @State private var hideOverlays = false
    /// Persisted collapsed/expanded state of the bottom-right keyboard-shortcuts
    /// hint card. Collapses to a small keyboard pill rather than disappearing, so
    /// the user can always re-expand it; state survives across sessions.
    @AppStorage("fullScreenShortcutsCollapsed") private var shortcutsCollapsed = false
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
    // The face whose name popover is open (keyed by face id, carrying its group id).
    @State private var renamingFace: RenamingFace?

    /// Identifies the face box whose inline rename popover is currently presented.
    private struct RenamingFace: Identifiable {
        let id: UUID        // face id — keeps the popover unique even when two faces share a group
        let groupID: UUID
        let initialName: String
    }

    // Zoom state
    @State private var zoomScale: CGFloat = 1.0
    @State private var lastZoomScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var isZoomedTo100: Bool = false
    @State private var sourcePixelSize: CGSize?
    /// URL + settings loadImage() last decoded. Used to tell an in-place edit (settings
    /// changed for the image on screen → must reload) apart from a navigation (handled by
    /// the .task(id:) below). Comparing settings too makes this robust to the order in
    /// which SwiftUI runs the .task body vs the onChange handler on a navigation — either
    /// way the reload is correctly skipped, so we don't discard the prefetched image.
    @State private var lastDecodedURL: URL?
    @State private var lastDecodedSettings: CameraRawSettings?
    /// Shared linear/nearest-neighbor scaling toggle (View menu + Option+S).
    @ObservedObject private var scaling = ImageScalingController.shared
    @State private var lastOrientationURL: URL?
    /// Display orientation already baked into `currentImage`. This is deliberately
    /// the target display orientation, not the embedded file tag: cache hits and
    /// thumbnail placeholders have already been corrected to sidecar orientation.
    @State private var lastLoadedOrientation: Int = 1

    /// Minimum zoom allows zooming out to 1:1 pixel mapping for small images.
    private var minZoom: CGFloat {
        min(calculateZoomTo100(), 1.0)
    }
    private let maxZoom: CGFloat = 40.0

    private var currentImageFile: ImageFile? {
        if let activeURL = viewModel.lastClickedImageURL,
           viewModel.selectedImageIDs.contains(activeURL),
           let index = viewModel.urlToImageIndex[activeURL] {
            return viewModel.images[index]
        }
        return viewModel.firstSelectedImage
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
                    HDRImageView(
                        cgImage: currentImage.cgImage,
                        isHDR: isHDR,
                        useNearestNeighbor: scaling.useNearestNeighbor,
                        onPanChanged: { translation in
                            updatePan(translation)
                        },
                        onPanEnded: { translation in
                            endPan(translation, in: geometry.size)
                        }
                    )
                        .aspectRatio(
                            currentImage.size.width / currentImage.size.height,
                            contentMode: .fit
                        )
                        .scaleEffect(zoomScale)
                        .offset(offset)
                        .gesture(magnifyGesture)
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
                    // Cold load only: while there's nothing on screen yet. Once any
                    // preview is up, background quality upgrades (retina Phase 2)
                    // happen silently — no overlay.
                    if isLoading && currentImage == nil {
                        loadingOverlay(
                            text: "Loading\u{2026}",
                            guidance: highResolutionLoadingGuidance
                        )
                    } else if isLoadingHires && zoomScale > 1.0 {
                        // Zoom-triggered full-resolution decode: the fit-view image is
                        // already sharp enough, so this overlay only appears when the
                        // user has zoomed in and is waiting for full detail.
                        loadingOverlay(
                            text: "Loading hires\u{2026}",
                            guidance: highResolutionLoadingGuidance
                        )
                    }

                    if let loadFailure {
                        loadFailureOverlay(loadFailure)
                    }

                    if let file = currentImageFile {
                        // Top-left: viewing-mode badge (original vs edited). Only meaningful when the
                        // image actually has edits — otherwise both modes render identically, so hide it.
                        if file.hasDevelopEdits || file.hasCropEdits {
                            VStack {
                                HStack {
                                    Label(renderEdits ? "Viewing edits" : "Viewing original",
                                          systemImage: renderEdits ? "slider.horizontal.3" : "photo")
                                        .font(.caption)
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background((renderEdits ? Color.orange : Color.gray).opacity(0.8), in: Capsule())
                                        .padding(.leading, 20)
                                        .padding(.top, 20)
                                    Spacer()
                                }
                                Spacer()
                            }
                        }

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

                        // Bottom-right: keyboard-shortcut tips (collapsible)
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                shortcutsHintCard(for: file)
                            }
                            .padding(.trailing, 20)
                            .padding(.bottom, 20)
                        }

                        // Bottom-center: filename + indicators
                        VStack {
                            Spacer()
                            VStack(spacing: 4) {
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
                                }

                                Text("Scaling: \(scaling.useNearestNeighbor ? "Nearest Neighbour" : "Bilinear")")
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.7))

                                if canOpenComparison {
                                    Button {
                                        onRequestComparison(renderEdits)
                                    } label: {
                                        Label("Compare", systemImage: "rectangle.split.2x1")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.white)
                                    .help("Compare with another image (C)")
                                    .accessibilityLabel("Compare current image with another image")
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
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
            // Full screen shows the edited version by default (Bridge-style);
            // press E to toggle back to the original. Respects the global
            // "show originals" preference.
            renderEdits = !viewModel.showOriginalThumbnails
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
            zoomController?.openComparisonAction = { [self] in
                onRequestComparison(renderEdits)
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
            isLoadingHires = false
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
            // Reload only for an in-place edit (e.g. mask adjustments committed in the
            // edit workspace) to the image already on screen. Navigation also changes
            // cameraRawSettings, but it's handled by the .task(id:) above — reloading
            // here too discarded the prefetched image and re-decoded from scratch.
            guard renderEdits, let url = currentImageFile?.url else { return }
            // Same image, and settings genuinely differ from what we last decoded.
            // Both guards together are robust to .task-vs-onChange ordering on nav.
            guard url == lastDecodedURL,
                  currentImageFile?.cameraRawSettings != lastDecodedSettings else { return }
            // Debounce: slider drags in the workspace fire many changes/sec; coalesce
            // into one reload after editing settles. Keep the current image on screen
            // (no blank) until the fresh render is ready.
            settingsReloadTask?.cancel()
            settingsReloadTask = Task {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                imageCache.invalidateImage(for: url)
                await loadImage()
            }
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
            let corrected = Self.applyOrientationCorrection(
                current.cgImage,
                fileOrientation: lastLoadedOrientation,
                targetOrientation: newValue
            )
            currentImage = makeLoadedImage(from: corrected)
            lastLoadedOrientation = newValue
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
        .imageDeletionConfirmation(
            viewModel: viewModel,
            isActiveHost: viewModel.isFullScreen
        )
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

    private func updatePan(_ translation: CGSize) {
        guard zoomScale > 1.0 else { return }
        offset = CGSize(
            width: lastOffset.width + translation.width,
            height: lastOffset.height + translation.height
        )
    }

    private func endPan(_ translation: CGSize, in size: CGSize) {
        guard zoomScale > 1.0 else {
            offset = .zero
            lastOffset = .zero
            return
        }
        offset = CGSize(
            width: lastOffset.width + translation.width,
            height: lastOffset.height + translation.height
        )
        lastOffset = offset
        constrainOffset(in: size)
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

        return CameraRawApproximation.createDisplayCGImage(processed, from: extent) ?? cgImage
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

    /// Mirror `EditWorkspaceView.autoEnableHDRIfNeeded`: a native-HDR image renders in HDR
    /// by default. The Metal edit shader only keeps super-white (>1.0) detail when the
    /// `hdrEditMode` flag is set — otherwise it gamut-clamps the output to SDR (see
    /// EditAdjustments.metal). The develop view force-enables this for native-HDR files, so
    /// the full-screen render must do the same: without it an *edited* native-HDR image gets
    /// SDR-clipped (it runs through the shader) while the *unedited* one stays HDR (it bypasses
    /// the shader entirely). Only fills an unset flag, so an explicit HDR-off (`0`) is honored.
    nonisolated private static func hdrNormalized(_ settings: CameraRawSettings?, isNativeHDR: Bool) -> CameraRawSettings? {
        guard isNativeHDR, var s = settings, s.hdrEditMode == nil else { return settings }
        s.hdrEditMode = 1
        return s
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
        // Stamp the rendered HDR pixels with their content headroom so the CALayer engages EDR
        // (a Metal-rendered CGImage otherwise reports unknown headroom and is excluded from
        // tone mapping → clamped to SDR). See CameraRawApproximation.createDisplayCGImage.
        return CameraRawApproximation.createDisplayCGImage(processed, from: extent)
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

    /// Bottom-right keyboard-shortcut tips. Collapses to a small keyboard pill
    /// (persisted in `shortcutsCollapsed`) instead of disappearing, so it can
    /// always be re-expanded. The "toggle edits" row only appears when the image
    /// actually has edits, since E is a no-op otherwise.
    @ViewBuilder
    private func shortcutsHintCard(for file: ImageFile) -> some View {
        if shortcutsCollapsed {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { shortcutsCollapsed = false }
            } label: {
                Image(systemName: "keyboard")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.55), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Show keyboard shortcuts")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Text("Shortcuts")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer(minLength: 16)
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { shortcutsCollapsed = true }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(3)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Collapse")
                }
                if file.hasDevelopEdits || file.hasCropEdits {
                    shortcutRow(
                        "E",
                        renderEdits ? "Turn off edits (faster high-res)" : "Show edits"
                    )
                }
                if canOpenComparison {
                    shortcutRow("C", "Compare with another image")
                }
                shortcutRow("H", "Hide interface")
                shortcutRow("Z", "Toggle 1:1 at cursor")
                shortcutRow("F", "Toggle face boxes")
                shortcutRow("\u{2325}S", "Toggle scaling filter")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func shortcutRow(_ key: String, _ label: String) -> some View {
        HStack(spacing: 8) {
            Text(key)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(minWidth: 18, alignment: .center)
                .padding(.horizontal, 3)
                .frame(height: 18)
                .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.75))
        }
    }

    private var highResolutionLoadingGuidance: String? {
        FullScreenLoadingGuidance.message(
            isRenderingEdits: renderEdits,
            hasEdits: currentImageFile.map { $0.hasDevelopEdits || $0.hasCropEdits } ?? false
        )
    }

    @ViewBuilder
    private func loadingOverlay(text: String, guidance: String?) -> some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
            Text(text)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
            if let guidance {
                Text(guidance)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func loadFailureOverlay(_ failure: FullScreenLoadFailure) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.white.opacity(0.7))
            Text(failure.message)
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
            if let guidance = highResolutionLoadingGuidance {
                Text(guidance)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            HStack(spacing: 8) {
                Button("Retry") {
                    loadFailure = nil
                    isLoading = true
                    Task { await loadImage() }
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([failure.url])
                }
                Button("Copy Details") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(failure.details, forType: .string)
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Image load failed")
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
        // New load: no retina result applied yet for this generation.
        hiResApplied = false

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
            loadFailure = nil
            return
        }
        loadFailure = nil
        // Record the image + settings we're decoding so onChange(cameraRawSettings) can
        // tell an in-place edit from a navigation (handled by .task(id:)).
        lastDecodedURL = url
        lastDecodedSettings = currentImageFile?.cameraRawSettings

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
        let isNativeHDR = currentImageFile?.isNativeHDR == true
        let modelCameraRaw = renderEdits ? currentImageFile?.cameraRawSettings : nil
        let sidecarCameraRaw = renderEdits && modelCameraRaw == nil
            ? XMPSidecarService().loadSidecar(for: url)?.cameraRaw
            : nil
        let cameraRaw = Self.hdrNormalized(modelCameraRaw ?? sidecarCameraRaw, isNativeHDR: isNativeHDR)
        let renderToken = FullScreenImageCache.renderToken(settings: cameraRaw, isEdited: isEdited)
        let needsHDRLoad = cameraRaw != nil || isNativeHDR
        let maskCount = cameraRaw?.localAdjustments?.count ?? 0
        let enabledMaskCount = cameraRaw?.localAdjustments?.filter(\.enabled).count ?? 0
        imageLogger.info("\(filename): renderEdits=\(renderEdits), cameraRaw=\(cameraRaw != nil), nativeHDR=\(isNativeHDR), masks=\(maskCount) (enabled=\(enabledMaskCount)), exp=\(cameraRaw?.exposure2012 ?? 0)")
        let imageOrientation = FullScreenImageCache.displayOrientation(
            for: url,
            fallback: currentImageFile?.exifOrientation ?? 1
        )

        // Read source pixel dimensions (cheap metadata-only, no pixel decode)
        let fileOrientation: Int
        // EXIF orientations 5-8 swap width/height after transform
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let pw = props[kCGImagePropertyPixelWidth] as? Int,
           let ph = props[kCGImagePropertyPixelHeight] as? Int {
            let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
            fileOrientation = orientation
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
        } else {
            sourcePixelSize = nil
            fileOrientation = imageOrientation
        }

        // File orientation = what the OS baked into the loaded pixels.
        // When it differs from imageOrientation (e.g. C2PA images where
        // the file isn't modified), applyCameraRaw applies corrective rotation.
        // An in-flight prefetch decodes this exact URL/orientation/render-token
        // variant, so reuse it instead of decoding twice during fast navigation.
        let cache = imageCache

        // If corrective rotation swaps width/height, adjust sourcePixelSize
        let delta = ImageFile.rotationDelta(from: fileOrientation, to: imageOrientation)
        if (delta == 1 || delta == 3), let size = sourcePixelSize {
            sourcePixelSize = CGSize(width: size.height, height: size.width)
        }

        // Phase 0: Instant — check retina cache, then display preview cache, then thumbnail
        if let cached = imageCache.cachedImage(
            for: url,
            orientation: imageOrientation,
            renderToken: renderToken,
            isEdited: isEdited
        ) {
            imageLogger.info("\(filename): Phase 0 cache hit (edited=\(isEdited))")
            currentImage = makeLoadedImage(from: cached)
            lastLoadedOrientation = imageOrientation
            isLoading = false
            triggerPrefetch(for: url)
            return
        }

        if let displayPreview = imageCache.cachedDisplayPreview(
            for: url,
            orientation: imageOrientation,
            renderToken: renderToken,
            isEdited: isEdited
        ) {
            imageLogger.info("\(filename): Phase 0 display preview cache hit (edited=\(isEdited))")
            currentImage = makeLoadedImage(from: displayPreview)
            lastLoadedOrientation = imageOrientation
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
                var image: CGImage? = await cache.awaitPrefetchedImage(
                    for: url,
                    orientation: imageOrientation,
                    renderToken: renderToken,
                    isEdited: isEdited
                )
                if image == nil, needsHDRLoad {
                    if isRAWFile {
                        // Use CIRAWFilter for flat/neutral decode — get as-shot WB for correct rendering.
                        // Decode straight to screen resolution (not full sensor then shrink) — the
                        // wasted full-sensor demosaic was the multi-second culling stall on RAW.
                        let rawFileOrientation = FullScreenImageCache.fileEXIFOrientation(at: url)
                        if let rawResult = FullScreenImageCache.loadRAWImage(from: url, draftMode: false, maxPixelSize: screenMaxPx) {
                            guard !Task.isCancelled else { return }
                            var settings = cameraRaw
                            settings?.asShotNeutralTemperature = Double(rawResult.neutralTemperature)
                            settings?.asShotNeutralTint = Double(rawResult.neutralTint)
                            settings?.sourceHasHDRHeadroom = true
                            let ciImage = FullScreenImageCache.downsample(rawResult.image, maxPixelSize: screenMaxPx)
                            image = Self.applyCameraRaw(to: ciImage, settings: settings, exifOrientation: imageOrientation, fileOrientation: rawFileOrientation)
                        }
                    } else {
                        if let result = await FullScreenImageCache.loadHDRPreviewOffPoolWithOrientation(from: url, maxPixelSize: screenMaxPx) {
                            guard !Task.isCancelled else { return }
                            image = Self.applyCameraRaw(to: result.image, settings: cameraRaw, exifOrientation: imageOrientation, fileOrientation: result.orientation)
                        }
                    }
                }
                guard !Task.isCancelled else { return }
                if image == nil {
                    guard let result = await FullScreenImageCache.loadDownsampledOffPoolWithOrientation(from: url, maxPixelSize: screenMaxPx) else {
                        imageLogger.error("\(filename, privacy: .private): Phase 2 failed — could not upgrade cached preview")
                        await MainActor.run {
                            if expectedGeneration == renderGeneration,
                               currentImageFile?.url == url {
                                loadFailure = FullScreenLoadFailure(
                                    url: url,
                                    isRenderingEdits: isEdited
                                )
                            }
                        }
                        return
                    }
                    guard !Task.isCancelled else { return }
                    let loaded = Self.applyCameraRaw(to: result.image, settings: cameraRaw, exifOrientation: imageOrientation, fileOrientation: result.orientation)
                    image = loaded
                }
                guard let image, !Task.isCancelled else { return }
                let fullElapsed = CFAbsoluteTimeGetCurrent() - fullStart
                await MainActor.run {
                    guard expectedGeneration == renderGeneration,
                          currentImageFile?.url == url else { return }
                    imageLogger.info("\(filename): Phase 2 done in \(String(format: "%.1f", fullElapsed * 1000))ms (\(image.width)x\(image.height))")
                    currentImage = makeLoadedImage(from: image)
                    hiResApplied = true
                    lastLoadedOrientation = imageOrientation
                    imageCache.store(
                        image,
                        for: url,
                        orientation: imageOrientation,
                        renderToken: renderToken,
                        isEdited: isEdited
                    )
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
            lastLoadedOrientation = imageOrientation
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
            var image: CGImage? = await cache.awaitPrefetchedImage(
                for: url,
                orientation: imageOrientation,
                renderToken: renderToken,
                isEdited: isEdited
            )
            if image == nil, needsHDRLoad {
                if isRAW {
                    // Use CIRAWFilter for flat/neutral decode — get as-shot WB for correct rendering.
                    // Decode straight to screen resolution (not full sensor then shrink).
                    let rawFileOrientation = FullScreenImageCache.fileEXIFOrientation(at: url)
                    if let rawResult = FullScreenImageCache.loadRAWImage(from: url, draftMode: false, maxPixelSize: screenMaxPx) {
                        guard !Task.isCancelled else { return }
                        var settings = cameraRaw
                        settings?.asShotNeutralTemperature = Double(rawResult.neutralTemperature)
                        settings?.asShotNeutralTint = Double(rawResult.neutralTint)
                        settings?.sourceHasHDRHeadroom = true
                        let ciImage = FullScreenImageCache.downsample(rawResult.image, maxPixelSize: screenMaxPx)
                        image = Self.applyCameraRaw(to: ciImage, settings: settings, exifOrientation: imageOrientation, fileOrientation: rawFileOrientation)
                    }
                } else {
                    if let result = await FullScreenImageCache.loadHDRPreviewOffPoolWithOrientation(from: url, maxPixelSize: screenMaxPx) {
                        guard !Task.isCancelled else { return }
                        image = Self.applyCameraRaw(to: result.image, settings: cameraRaw, exifOrientation: imageOrientation, fileOrientation: result.orientation)
                    }
                }
            }
            guard !Task.isCancelled else { return }
            if image == nil {
                guard let result = await FullScreenImageCache.loadDownsampledOffPoolWithOrientation(from: url, maxPixelSize: screenMaxPx) else {
                    imageLogger.error("\(filename, privacy: .private): Phase 2 failed — could not decode image")
                    await MainActor.run {
                        if expectedGeneration == renderGeneration,
                           currentImageFile?.url == url {
                            isLoading = false
                            loadFailure = FullScreenLoadFailure(
                                url: url,
                                isRenderingEdits: isEdited
                            )
                        }
                    }
                    return
                }
                guard !Task.isCancelled else { return }
                let loaded = Self.applyCameraRaw(to: result.image, settings: cameraRaw, exifOrientation: imageOrientation, fileOrientation: result.orientation)
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
                    hiResApplied = true
                    lastLoadedOrientation = imageOrientation
                    isLoading = false
                    loadFailure = nil
                    imageCache.store(
                        image,
                        for: url,
                        orientation: imageOrientation,
                        renderToken: renderToken,
                        isEdited: isEdited
                    )
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
        let p05 = Task.detached(priority: .medium) { () -> CGImage? in
            guard !Task.isCancelled else { return nil }
            if isRAW {
                // Sidecar-rotated RAWs can have embedded camera previews whose pixel
                // orientation does not match the full CIRAWFilter decode. Showing/caching
                // that fast JPEG causes the loupe to flash, or get stuck after rapid
                // navigation, at 90 degrees while Phase 2 later renders the correct 180.
                // Keep the thumbnail placeholder up and let Phase 2 be the first RAW
                // bitmap for these files.
                guard fileOrientation == imageOrientation else {
                    imageLogger.info("\(filename): Phase 0.5 skipped for sidecar-rotated RAW (fileOrientation=\(fileOrientation), displayOrientation=\(imageOrientation))")
                    return nil
                }
                guard let raw = await FullScreenImageCache.extractEmbeddedPreviewOffPoolWithOrientation(from: url) else { return nil }
                guard !Task.isCancelled else { return nil }
                return Self.applyCameraRaw(to: raw.image, settings: cameraRaw, exifOrientation: imageOrientation, fileOrientation: raw.orientation)
            }
            // Try HDR CIImage path first; fall through to CGImage if crop/render fails
            if needsHDRLoad,
               let result = await FullScreenImageCache.loadHDRPreviewOffPoolWithOrientation(from: url, maxPixelSize: 960) {
                guard !Task.isCancelled else { return nil }
                if let image = Self.applyCameraRaw(to: result.image, settings: cameraRaw, exifOrientation: imageOrientation, fileOrientation: result.orientation) {
                    return image
                }
            }
            // CGImage fallback — applyCameraRaw(to: CGImage) always returns a valid image
            guard !Task.isCancelled else { return nil }
            guard let raw = await FullScreenImageCache.loadDownsampledOffPoolWithOrientation(from: url, maxPixelSize: 960) else { return nil }
            guard !Task.isCancelled else { return nil }
            return Self.applyCameraRaw(to: raw.image, settings: cameraRaw, exifOrientation: imageOrientation, fileOrientation: raw.orientation)
        }
        phase05Task = p05
        let preview = await p05.value
        let previewElapsed = CFAbsoluteTimeGetCurrent() - previewStart
        guard !Task.isCancelled else { return }
        if let preview,
           expectedGeneration == renderGeneration,
           currentImageFile?.url == url {
            // Always cache the preview, but only show it if Phase 2 (retina) hasn't
            // already won the race — otherwise we'd downgrade a sharp image.
            imageCache.storeDisplayPreview(
                preview,
                for: url,
                orientation: imageOrientation,
                renderToken: renderToken,
                isEdited: isEdited
            )
            if !hiResApplied {
                imageLogger.info("\(filename): Phase 0.5 in \(String(format: "%.1f", previewElapsed * 1000))ms (\(preview.width)x\(preview.height))")
                currentImage = makeLoadedImage(from: preview)
                lastLoadedOrientation = imageOrientation
            } else {
                imageLogger.info("\(filename): Phase 0.5 ready but retina already applied — keeping hi-res")
            }
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
        let isNativeHDR = currentImageFile?.isNativeHDR == true
        let modelCameraRaw = renderEdits ? currentImageFile?.cameraRawSettings : nil
        let sidecarCameraRaw = renderEdits && modelCameraRaw == nil
            ? XMPSidecarService().loadSidecar(for: url)?.cameraRaw
            : nil
        let cameraRaw = Self.hdrNormalized(modelCameraRaw ?? sidecarCameraRaw, isNativeHDR: isNativeHDR)
        let needsHDRFullRes = cameraRaw != nil || isNativeHDR
        let isRAWFile = SupportedImageFormats.isRaw(url: url)
        let orientation = FullScreenImageCache.displayOrientation(
            for: url,
            fallback: currentImageFile?.exifOrientation ?? 1
        )
        let expectedGeneration = renderGeneration
        imageLogger.info("\(filename): Loading full resolution for zoom")
        // Hi-res overlay (not the cold-load overlay): the fit-view image is
        // already on screen and sharp enough; this only signals the zoom upgrade.
        isLoadingHires = true
        fullResTask = Task.detached(priority: .medium) {
            let fullStart = CFAbsoluteTimeGetCurrent()
            var image: CGImage?
            if !Task.isCancelled, needsHDRFullRes {
                if isRAWFile {
                    // Use CIRAWFilter for flat/neutral full-res decode — get as-shot WB
                    let rawFileOrientation = FullScreenImageCache.fileEXIFOrientation(at: url)
                    if let rawResult = FullScreenImageCache.loadRAWImage(from: url, draftMode: false), !Task.isCancelled {
                        var settings = cameraRaw
                        settings?.asShotNeutralTemperature = Double(rawResult.neutralTemperature)
                        settings?.asShotNeutralTint = Double(rawResult.neutralTint)
                        settings?.sourceHasHDRHeadroom = true
                        image = Self.applyCameraRaw(to: rawResult.image, settings: settings, exifOrientation: orientation, fileOrientation: rawFileOrientation)
                    }
                } else {
                    if let result = await FullScreenImageCache.loadHDRFullResolutionOffPoolWithOrientation(from: url), !Task.isCancelled {
                        image = Self.applyCameraRaw(to: result.image, settings: cameraRaw, exifOrientation: orientation, fileOrientation: result.orientation)
                    }
                }
            }
            if image == nil, !Task.isCancelled,
               let result = await FullScreenImageCache.loadFullResolutionOffPoolWithOrientation(from: url),
               !Task.isCancelled {
                image = Self.applyCameraRaw(to: result.image, settings: cameraRaw, exifOrientation: orientation, fileOrientation: result.orientation)
            }
            let elapsed = CFAbsoluteTimeGetCurrent() - fullStart
            // Always hop to main to clear the overlay, even on cancel/failure, so
            // "Loading hires…" can never get stuck.
            await MainActor.run {
                guard expectedGeneration == renderGeneration,
                      currentImageFile?.url == url else { return }
                isLoadingHires = false
                guard let image else { return }
                imageLogger.info("\(filename): Full resolution loaded in \(String(format: "%.1f", elapsed * 1000))ms (\(image.width)x\(image.height))")
                currentImage = makeLoadedImage(from: image)
                lastLoadedOrientation = orientation
                isFullResLoaded = true
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
                // Match the foreground render's HDR normalization so prefetched edited
                // images aren't SDR-clipped (see hdrNormalized).
                if let settings = Self.hdrNormalized(image.cameraRawSettings, isNativeHDR: image.isNativeHDR) {
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

    /// Maps a detection rect (Vision-normalized, bottom-left origin, in the full
    /// display-oriented image frame) into display-space corners, replicating the
    /// crop + straighten geometry that `CameraRawApproximation.applyCrop` bakes into
    /// the rendered image. Without an effective crop this reduces to a plain
    /// aspect-fit placement (the old `convertFaceRect` behaviour).
    ///
    /// Returns four corners (TL, TR, BR, BL in display space) so callers can stroke a
    /// quad that follows the straighten angle — an axis-aligned rect would drift out
    /// of alignment once the crop is rotated.
    private func detectionCorners(
        _ rect: CGRect,
        crop: CameraRawCrop?,
        imageSize: CGSize,
        in imageDisplayRect: CGRect
    ) -> [CGPoint] {
        // Corners in normalized full-image space, y-up (Vision convention):
        // TL, TR, BR, BL as they appear upright in the displayed image.
        let normCorners = [
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.minY),
        ]

        // Plain aspect-fit placement when there is no crop to follow.
        func placedDirectly() -> [CGPoint] {
            normCorners.map { p in
                CGPoint(
                    x: imageDisplayRect.minX + p.x * imageDisplayRect.width,
                    y: imageDisplayRect.minY + (1.0 - p.y) * imageDisplayRect.height
                )
            }
        }

        guard let crop, crop.isEffectiveCrop,
              imageSize.width > 0, imageSize.height > 0 else {
            return placedDirectly()
        }

        // Express the crop in the same display-oriented frame the face boxes live in,
        // exactly as applyCrop does before rendering.
        let dc = crop.transformedForDisplay(orientation: currentImageFile?.exifOrientation ?? 1)
        let left = min(dc.left ?? 0, dc.right ?? 1)
        let right = max(dc.left ?? 0, dc.right ?? 1)
        let top = min(dc.top ?? 0, dc.bottom ?? 1)
        let bottom = max(dc.top ?? 0, dc.bottom ?? 1)
        let fracW = right - left
        let fracH = bottom - top
        guard fracW > 0.0001, fracH > 0.0001 else { return placedDirectly() }

        // The renderer outputs exactly fracW·Wf × fracH·Hf pixels, so the full-image
        // pixel dimensions can be recovered from the rendered (cropped) size. Only the
        // aspect ratio matters (absolute scale cancels below), but using real pixels
        // keeps the rotation math identical to applyCrop.
        let wf = imageSize.width / fracW
        let hf = imageSize.height / fracH
        let cx = wf / 2, cy = hf / 2
        // y-up, +angle — matches applyCrop's CGAffineTransform(rotationAngle:).
        let theta = (dc.angle ?? 0) * .pi / 180.0
        let cosT = cos(theta), sinT = sin(theta)

        let cropW = imageSize.width   // == fracW · wf
        let cropH = imageSize.height  // == fracH · hf
        // Upright crop centre in full-image pixels (y-up: top edge is high y).
        let cropCenterX = (left * wf) + cropW / 2
        let cropCenterY = ((1 - bottom) * hf) + cropH / 2
        // Rotate the crop centre about the image centre, as applyCrop does.
        let rcx = cropCenterX - cx, rcy = cropCenterY - cy
        let newCenterX = cx + rcx * cosT - rcy * sinT
        let newCenterY = cy + rcx * sinT + rcy * cosT
        let cropOriginX = newCenterX - cropW / 2
        let cropOriginY = newCenterY - cropH / 2

        return normCorners.map { p in
            let px = p.x * wf, py = p.y * hf
            let dx = px - cx, dy = py - cy
            let rx = cx + dx * cosT - dy * sinT
            let ry = cy + dx * sinT + dy * cosT
            let u = (rx - cropOriginX) / cropW
            let v = (ry - cropOriginY) / cropH
            return CGPoint(
                x: imageDisplayRect.minX + u * imageDisplayRect.width,
                y: imageDisplayRect.minY + (1.0 - v) * imageDisplayRect.height
            )
        }
    }

    /// Closed quad path through four display-space corners.
    private func quadPath(_ corners: [CGPoint]) -> Path {
        var path = Path()
        guard let first = corners.first else { return path }
        path.move(to: first)
        for corner in corners.dropFirst() { path.addLine(to: corner) }
        path.closeSubpath()
        return path
    }

    @ViewBuilder
    private func faceRectanglesOverlay(imageSize: CGSize, containerSize: CGSize) -> some View {
        let faceContext = viewModel.fullScreenFaceContext
        let highlightedFaceID = faceContext?.highlightedFaceID
        let imageDisplayRect = calculateImageDisplayRect(imageSize: imageSize, in: containerSize)

        if let faceVM = faceContext?.faceRecognitionViewModel,
           let url = currentImageFile?.url {
            let facesInImage = faceVM.facesForImage(url)
            let showsSportsNumbers = faceVM.activeLens == .sports
            let standaloneNumbers = showsSportsNumbers ? faceVM.numberDetectionsForImage(url) : []
            // Follow the crop/straighten geometry baked into the rendered image so the
            // boxes stay glued to faces and numbers after a rotated crop.
            let displayCrop = renderEdits ? currentImageFile?.cameraRawSettings?.crop : nil
            ZStack {
                Canvas { context, _ in
                    for face in facesInImage {
                        let isHighlighted = face.id == highlightedFaceID
                        let corners = detectionCorners(face.faceRect, crop: displayCrop, imageSize: imageSize, in: imageDisplayRect)
                        let groupColor = colorForGroup(face.groupID)
                        let lineWidth: CGFloat = isHighlighted ? 4 : 2
                        let opacity: CGFloat = isHighlighted ? 1.0 : 0.5
                        context.stroke(quadPath(corners), with: .color(groupColor.opacity(opacity)), lineWidth: lineWidth)
                        // Named faces get a tag under the box, mirroring the jersey-number
                        // tags. In sports mode the player's number is prefixed: "9 Alice".
                        if let groupID = face.groupID, let name = faceVM.groupName(groupID) {
                            let label = faceVM.groupNumber(groupID).map { "#\($0) \(name)" } ?? name
                            drawTag(
                                context: context,
                                text: label,
                                box: quadPath(corners).boundingRect,
                                color: groupColor,
                                imageDisplayRect: imageDisplayRect,
                                preferBelow: true
                            )
                        }
                    }

                    if showsSportsNumbers {
                        // Jersey-number debug boxes (sports tagging): solid orange for numbers
                        // attached to a face's torso, red for standalone (back-turned) detections.
                        for face in facesInImage {
                            guard let number = face.jerseyNumber, let box = face.jerseyNumberBox else { continue }
                            drawNumberBox(
                                context: context,
                                corners: detectionCorners(box, crop: displayCrop, imageSize: imageSize, in: imageDisplayRect),
                                number: number,
                                confidence: face.numberConfidence,
                                color: .orange,
                                imageDisplayRect: imageDisplayRect
                            )
                        }
                        for detection in standaloneNumbers {
                            drawNumberBox(
                                context: context,
                                corners: detectionCorners(detection.boundingBox, crop: displayCrop, imageSize: imageSize, in: imageDisplayRect),
                                number: detection.number,
                                confidence: detection.numberConfidence,
                                color: .red,
                                imageDisplayRect: imageDisplayRect
                            )
                        }
                    }
                }
                .allowsHitTesting(false)

                // Click a face box to name/rename it. Only faces with a group are
                // addressable (synthetic-only faces have nothing to persist a name to).
                ForEach(facesInImage, id: \.id) { face in
                    if let groupID = face.groupID {
                        let box = quadPath(detectionCorners(face.faceRect, crop: displayCrop, imageSize: imageSize, in: imageDisplayRect)).boundingRect
                        Color.clear
                            .contentShape(Rectangle())
                            .frame(width: max(box.width, 12), height: max(box.height, 12))
                            .position(x: box.midX, y: box.midY)
                            .onTapGesture {
                                renamingFace = RenamingFace(id: face.id, groupID: groupID, initialName: faceVM.groupName(groupID) ?? "")
                            }
                            .popover(isPresented: Binding(
                                get: { renamingFace?.id == face.id },
                                set: { if !$0 { renamingFace = nil } }
                            )) {
                                FaceNamePopover(initialName: renamingFace?.initialName ?? "") { newName in
                                    faceVM.nameGroup(groupID, name: newName.trimmingCharacters(in: .whitespacesAndNewlines))
                                    renamingFace = nil
                                }
                            }
                    }
                }
            }
        }
    }

    /// Stroke a detected jersey-number box and draw a "#9 81%" tag above it (below it when
    /// the box touches the top of the image).
    private func drawNumberBox(
        context: GraphicsContext,
        corners: [CGPoint],
        number: Int,
        confidence: Float?,
        color: Color,
        imageDisplayRect: CGRect
    ) {
        context.stroke(quadPath(corners), with: .color(color.opacity(0.9)), lineWidth: 2)
        var label = "#\(number)"
        // Vision reports only coarse confidences (≈0.3/0.5/1.0); a full-confidence tag is
        // pure noise, so only flag the uncertain ones.
        if let confidence, confidence < 0.99 {
            label += " \(Int(confidence * 100))%"
        }
        // Anchor the tag off the quad's upright bounding box so it stays legible even
        // when the box is rotated by the straighten angle.
        drawTag(
            context: context,
            text: label,
            box: quadPath(corners).boundingRect,
            color: color,
            imageDisplayRect: imageDisplayRect,
            preferBelow: false
        )
    }

    /// Draw a small filled "#9" / "Alice" tag hugging `box` (display space). Sits above
    /// the box by default and flips below when it would clip the image's top edge; pass
    /// `preferBelow: true` for name tags, which read better under the face.
    private func drawTag(
        context: GraphicsContext,
        text: String,
        box: CGRect,
        color: Color,
        imageDisplayRect: CGRect,
        preferBelow: Bool
    ) {
        let resolved = context.resolve(
            Text(text)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
        )
        let textSize = resolved.measure(in: CGSize(width: 240, height: 40))
        let tagHeight = textSize.height + 2
        let aboveY = box.minY - tagHeight - 2
        let belowY = box.maxY + 2
        let y: CGFloat
        if preferBelow {
            y = (belowY + tagHeight <= imageDisplayRect.maxY) ? belowY : max(aboveY, imageDisplayRect.minY)
        } else {
            y = (aboveY >= imageDisplayRect.minY) ? aboveY : belowY
        }
        let tagRect = CGRect(x: box.minX, y: y, width: textSize.width + 8, height: tagHeight)
        context.fill(Path(roundedRect: tagRect, cornerRadius: 3), with: .color(color.opacity(0.85)))
        context.draw(resolved, at: CGPoint(x: tagRect.midX, y: tagRect.midY), anchor: .center)
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
    let canOpenComparison: Bool
    let onRequestComparison: (Bool) -> Void
    let onDismissed: () -> Void
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
        window.onOpenComparison = canOpenComparison ? { [weak controller] in
            controller?.openComparison()
        } : nil
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
            rootView: FullScreenImageView(
                viewModel: viewModel,
                scopeViewModel: scopeViewModel,
                canOpenComparison: canOpenComparison,
                onRequestComparison: onRequestComparison,
                zoomController: controller
            )
        )
        hostingView.wantsLayer = true
        if #available(macOS 26.0, *) {
            hostingView.layer?.preferredDynamicRange = CALayer.DynamicRange.high
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
        onDismissed()
    }
}

extension View {
    func fullScreenImagePresenter(
        viewModel: BrowserViewModel,
        scopeViewModel: ScopeViewModel,
        canOpenComparison: Bool = false,
        onRequestComparison: @escaping (Bool) -> Void = { _ in },
        onDismissed: @escaping () -> Void = {}
    ) -> some View {
        modifier(
            FullScreenPresenter(
                viewModel: viewModel,
                scopeViewModel: scopeViewModel,
                canOpenComparison: canOpenComparison,
                onRequestComparison: onRequestComparison,
                onDismissed: onDismissed
            )
        )
    }
}

/// Inline name/rename field shown in a popover when a face box is clicked in the
/// full-screen viewer. Commits on Return or the Save button.
private struct FaceNamePopover: View {
    let initialName: String
    let onCommit: (String) -> Void

    @State private var name: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Person name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 220)
                .focused($focused)
                .onChange(of: name) { _, newValue in
                    // Names are single-line.
                    let filtered = newValue.replacingOccurrences(of: "\n", with: "")
                        .replacingOccurrences(of: "\r", with: "")
                    if filtered != newValue { name = filtered }
                }
                .onSubmit { onCommit(name) }
            HStack {
                Spacer()
                Button("Save") { onCommit(name) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .onAppear {
            name = initialName
            focused = true
        }
    }
}
