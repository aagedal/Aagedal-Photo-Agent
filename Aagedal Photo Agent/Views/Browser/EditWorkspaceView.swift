import AppKit
import CoreImage
import os
import SwiftUI
import UniformTypeIdentifiers

nonisolated private let editLog = Logger(
    subsystem: "com.aagedal.photo-agent", category: "EditWorkspace"
)

private enum DevelopVersionNameAction: Identifiable, Equatable {
    case create
    case rename(UUID)
    case duplicate(UUID)

    var id: String {
        switch self {
        case .create: "create"
        case let .rename(id): "rename-\(id.uuidString)"
        case let .duplicate(id): "duplicate-\(id.uuidString)"
        }
    }

    var title: String {
        switch self {
        case .create: "New Version from Current"
        case .rename: "Rename Version"
        case .duplicate: "Duplicate Version"
        }
    }

    var actionLabel: String {
        switch self {
        case .create: "Create"
        case .rename: "Rename"
        case .duplicate: "Duplicate"
        }
    }
}

private struct DevelopVersionDialogsModifier: ViewModifier {
    @Binding var nameAction: DevelopVersionNameAction?
    @Binding var nameDraft: String
    @Binding var pendingDeleteID: UUID?
    @Binding var pendingPromotionID: UUID?
    let promotionMessage: String
    let performNameAction: () -> Void
    let deleteVersion: (UUID) -> Void
    let promoteVersion: (UUID) -> Void

    private var nameActionPresented: Binding<Bool> {
        Binding(
            get: { nameAction != nil },
            set: {
                if !$0 {
                    nameAction = nil
                    nameDraft = ""
                }
            }
        )
    }

    private var deletePresented: Binding<Bool> {
        Binding(
            get: { pendingDeleteID != nil },
            set: { if !$0 { pendingDeleteID = nil } }
        )
    }

    private var promotionPresented: Binding<Bool> {
        Binding(
            get: { pendingPromotionID != nil },
            set: { if !$0 { pendingPromotionID = nil } }
        )
    }

    func body(content: Content) -> some View {
        content
            .alert(
                nameAction?.title ?? "Develop Version",
                isPresented: nameActionPresented
            ) {
                TextField("Version name", text: $nameDraft)
                Button(nameAction?.actionLabel ?? "Save") {
                    performNameAction()
                }
                .disabled(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(
                "Delete this named version?",
                isPresented: deletePresented,
                titleVisibility: .visible
            ) {
                Button("Delete Version", role: .destructive) {
                    guard let id = pendingDeleteID else { return }
                    deleteVersion(id)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The named snapshot will be removed. Primary XMP settings are not changed.")
            }
            .confirmationDialog(
                "Promote this version to Primary?",
                isPresented: promotionPresented,
                titleVisibility: .visible
            ) {
                Button("Promote and Verify") {
                    guard let id = pendingPromotionID else { return }
                    promoteVersion(id)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(promotionMessage)
            }
    }
}

/// Shared semantics for the Global and per-mask anonymizer switches. Keeping the default here
/// prevents the two control panels from drifting apart while leaving imported strengths intact.
nonisolated enum AnonymizerToggleBehavior {
    static let defaultAmount = 30.0

    static func isEnabled(_ settings: AnonymizerSettings?) -> Bool {
        settings?.isEmpty == false
    }

    static func setEnabled(_ enabled: Bool, settings: inout AnonymizerSettings?) {
        guard enabled else {
            settings = nil
            return
        }
        if settings?.isEmpty != false {
            settings = AnonymizerSettings(amount: defaultAmount, blackOut: nil)
        }
    }
}

/// Resets only adjustments owned by the Global node. Image framing, local masks, watermarks,
/// layer order, HDR display mode, and per-image preservation metadata deliberately survive.
nonisolated enum GlobalLayerResetBehavior {
    static func reset(_ settings: inout CameraRawSettings, isRaw: Bool) {
        settings.whiteBalance = isRaw ? "As Shot" : nil
        settings.temperature = nil
        settings.tint = nil
        settings.incrementalTemperature = nil
        settings.incrementalTint = nil
        settings.exposure2012 = nil
        settings.contrast2012 = nil
        settings.highlights2012 = nil
        settings.shadows2012 = nil
        settings.whites2012 = nil
        settings.blacks2012 = nil
        settings.saturation = nil
        settings.vibrance = nil
        settings.globalDensity = nil
        settings.sharpness = nil
        settings.clarity2012 = nil
        settings.dehaze = nil
        settings.hdrMaxValue = nil
        settings.sdrBrightness = nil
        settings.sdrContrast = nil
        settings.sdrClarity = nil
        settings.sdrHighlights = nil
        settings.sdrShadows = nil
        settings.sdrWhites = nil
        settings.sdrBlend = nil
        settings.toneCurve = nil
        settings.hslAdjustments = nil
        settings.anonymizer = nil
        settings.filmEmulation = nil
    }
}

/// Maps a pointer in preview-pane coordinates to the display-frame UV used by mask overlays.
/// Returns nil over letterboxing/outside-image areas so callers can retain a safe fallback.
nonisolated enum EditPreviewCoordinateMapper {
    static func displayUV(
        forPanePoint point: CGPoint,
        paneSize: CGSize,
        viewportOrigin: SIMD2<Float>,
        viewportSize: SIMD2<Float>
    ) -> CGPoint? {
        guard paneSize.width > 0, paneSize.height > 0,
              viewportSize.x > 0, viewportSize.y > 0 else { return nil }

        let x = Double(viewportOrigin.x)
            + Double(point.x / paneSize.width) * Double(viewportSize.x)
        let y = Double(viewportOrigin.y)
            + Double(point.y / paneSize.height) * Double(viewportSize.y)
        guard x >= 0, x < 1, y >= 0, y < 1 else { return nil }
        return CGPoint(x: x, y: y)
    }
}

/// Crop handles need breathing room around the image while the crop tool is open. Once the
/// crop is confirmed, the result should use the entire preview pane like any other image.
nonisolated enum EditCropPreviewFraming {
    /// Leaves room for both the crop handles and the bottom crop toolbar.
    static let cropToolHandlePadding: CGFloat = 64

    static func handlePadding(isCropToolActive: Bool) -> CGFloat {
        isCropToolActive ? cropToolHandlePadding : 0
    }
}

struct EditWorkspaceView: View {
    @Environment(AppCommandRouter.self) private var commandRouter
    @Bindable var metadataViewModel: MetadataViewModel
    @Bindable var browserViewModel: BrowserViewModel
    let settingsViewModel: SettingsViewModel
    let scopeViewModel: ScopeViewModel
    let cleanFeedController: CleanFeedController
    let onExit: () -> Void
    var onPendingStatusChanged: (() -> Void)?

    @State private var sourceImage: NSImage?
    @State private var sourceCIImage: CIImage?
    @State private var isDraggingEditSlider = false
    @State private var previewCIImage: CIImage?
    @State private var previewRender = DevelopPreviewRenderCoordinator()
    @State private var developComparison = DevelopComparisonRenderCoordinator()
    @State private var developVersionSession = DevelopVersionSessionCoordinator()
    @State private var developVersionFlushRegistrationID: UUID?
    @State private var developVersionNameAction: DevelopVersionNameAction?
    @State private var developVersionNameDraft = ""
    @State private var developVersionPendingDeleteID: UUID?
    @State private var developVersionPendingPromotionID: UUID?
    /// Owns source URL/orientation, loading progress, and the tasks for preview decode/render,
    /// adjacent-RAW precaching, and lazy full-resolution zoom upgrades. One image-session boundary
    /// prevents previous-image work from publishing stale pixels or retaining decode graphs.
    @State private var previewSession = DevelopPreviewSessionCoordinator()
    @State private var isSavingRenderedJPEG = false
    @State private var saveError: String?
    @State private var copyPasteFeedback: String?
    /// Owns crop-tool presentation, image-scoped pointer state, preview zoom, aspect selection,
    /// and the value-mutation seam used before the view commits XMP or a named Develop version.
    @State private var cropSession = DevelopCropSessionCoordinator()
    @State private var isCursorOverPreview = false
    @State private var scrollEventMonitor: Any?
    @State private var keyEventMonitor: Any?
    @State private var middleMouseEventMonitor: Any?
    @State private var hoveredFilmstripURL: URL?
    /// Hold-Space override for panning the zoomed preview. A transparent drag surface is
    /// installed above the active brush/mask/watermark overlay while this is true, so the
    /// current editing tool remains selected but temporarily gives up pointer input.
    @State private var isSpaceHandToolActive = false
    /// Set only by left/right keyboard navigation so the filmstrip follows keyboard selection
    /// without recentering itself when the user clicks or extends a selection with the mouse.
    @State private var filmstripKeyboardScrollTarget: URL?
    /// Owns press-and-hold before/Develop/current-layer comparisons and projects them onto
    /// render-only settings copies so transient keyboard state never mutates editable metadata.
    @State private var transientPreview = DevelopTransientPreviewCoordinator()
    /// Owns sticky render-only section eye toggles for this workspace lifetime. Unlike held-key
    /// comparisons, these deliberately survive image navigation.
    @State private var sectionMutes = DevelopSectionMuteCoordinator()
    @State private var editUndoManager = UndoManager()
    @State private var watermarkStore = WatermarkStore.shared
    /// URLs whose develop settings actually changed during this edit session. On exit these are
    /// proactively re-rendered into the full-screen + thumbnail caches so the return to culling is
    /// instant and correct, rather than catching up reactively a beat later. Populated wherever
    /// edits are written back to `images[].cameraRawSettings`; consumed in `handleEditWorkspaceDisappear`.
    @State private var editedURLsThisSession: Set<URL> = []
    @State private var metalPipeline: MetalLivePreviewPipeline?
    @State private var metalCoordinator = MetalPreviewView.Coordinator()
    /// The selected node in the layer chain. `.global` shows the global adjustment sliders;
    /// `.mask(id)` shows that mask's sliders and overlay. Identity-based so it survives reorder.
    @State private var selectedLayer: LayerRef = .global
    /// The layer card currently being dragged for reorder, and the card it's hovering over.
    @State private var draggingLayer: LayerRef?
    @State private var dropTargetLayer: LayerRef?
    @State private var hoveredLayer: LayerRef?
    @State private var hoveredAddLayerKind: LayerKind?
    @State private var isShowingLayerRename = false
    @State private var layerBeingRenamed: LayerRef?
    @State private var layerNameDraft = ""
    @State private var isDraggingMask = false
    @State private var dragMaskGeometry: EllipseMaskGeometry?
    @State private var dragWatermarkGeometry: WatermarkGeometry?
    /// Global visibility for interactive ellipse outlines/handles. Kept separate from the
    /// selected mask's enabled state so users can inspect the adjusted image without deselecting.
    @State private var showsMaskOutlines = true
    /// Shown when "Add Watermark" is tapped but the Watermark library (Settings ▸ Watermarks)
    /// has no PNGs imported yet.
    @State private var showWatermarkLibraryEmptyAlert = false
    @State private var isShowingLUTImporter = false
    @State private var importingLUTForLayerID: UUID?
    @State private var colorLUTImportTask: Task<Void, Never>?
    @State private var colorLUTImportRequestID: UUID?
    @State private var colorTransformError: String?
    @State private var scopeThrottleTask: Task<Void, Never>?
    @State private var lastScopeUpdateTime: ContinuousClock.Instant = .now
    /// Owns the paired live/committed zoom and pan values used by scroll, magnify, keyboard,
    /// and drag input. Preview geometry and Metal publication remain at this view boundary.
    @State private var previewNavigation = DevelopPreviewNavigationCoordinator()
    @State private var previewPaneFrame: CGRect = .zero
    @State private var isHoveringHDR = false
    @State private var asShotWhiteBalance: (temperature: Float, tint: Float)?
    /// White-balance eyedropper mode: when on, the preview shows a crosshair and a
    /// click (or drag-rectangle) sets the WB from the sampled area.
    @State private var isPickingWhiteBalance = false
    /// Live marquee rectangle (preview-pane coordinates) drawn while dragging a WB sample.
    @State private var wbPickDragRect: CGRect?

    // Image-scoped brush and matte-hover gesture state. Brush preferences survive navigation;
    // active pointer interactions do not.
    @State private var maskInteraction = DevelopMaskInteractionCoordinator()
    // AI subject/object selection owns one click over the preview. No layer is added until Vision
    // returns a real foreground instance, so cancelling or clicking the letterbox leaves no junk.
    @State private var aiMaskSelection = AIMaskSelectionCoordinator()
    @FocusState private var isWorkspaceFocused: Bool
    @ObservedObject private var scaling = ImageScalingController.shared

    private static let previewBackground = Color(red: 0.15, green: 0.15, blue: 0.15)

    // RAW: absolute Kelvin slider. The 2000 K floor matches CITemperatureAndTint's neutral
    // limit — it silently returns an identity (no-op) transform below 2000 K. Adobe Camera RAW
    // goes down to 1500 K; we can't represent that, so colder imported values are clamped at
    // render time and flagged via hasUnrepresentableWhiteBalance.
    // Non-RAW: relative WB slider (see nonRawIncrementalTempRange).
    private static let minKelvin = 2000.0
    private static let maxKelvin = 50000.0
    // -135 maps to the 2000 K floor (6500 - 135*33.33 ≈ 2000); going colder would hit
    // CITemperatureAndTint's identity floor, so the slider stops there.
    private static let nonRawIncrementalTempRange: ClosedRange<Double> = -135...100

    private var previewWorkingMaxPixelSize: CGFloat {
        let screenSize = NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)
        let screenScale = NSScreen.main?.backingScaleFactor ?? 2.0
        let maxScreenPixel = max(screenSize.width, screenSize.height) * screenScale
        return min(max(maxScreenPixel, 1600), 3200)
    }

    private var selectedImage: ImageFile? {
        if let anchor = browserViewModel.lastClickedImageURL,
           browserViewModel.selectedImageIDs.contains(anchor),
           let anchored = browserViewModel.images.first(where: { $0.url == anchor }) {
            return anchored
        }
        if let selected = browserViewModel.selectedImages.first {
            return selected
        }
        return browserViewModel.visibleImages.first
    }

    private var selectedImageURL: URL? {
        selectedImage?.url
    }

    // Transitional aliases keep the decode/render implementation compact while
    // `DevelopPreviewSessionCoordinator` remains the sole owner of image-scoped progress,
    // source identity, and cancellable preview work.
    private var isLoadingPreview: Bool {
        get { previewSession.isLoadingPreview }
        nonmutating set { previewSession.isLoadingPreview = newValue }
    }

    private var isDecodingFullResolution: Bool {
        get { previewSession.isDecodingFullResolution }
        nonmutating set { previewSession.isDecodingFullResolution = newValue }
    }

    private var isEditFullResLoaded: Bool {
        get { previewSession.isEditFullResLoaded }
        nonmutating set { previewSession.isEditFullResLoaded = newValue }
    }

    private var previewTask: Task<Void, Never>? {
        get { previewSession.sourceLoadTask }
        nonmutating set { previewSession.replaceSourceLoadTask(with: newValue) }
    }

    private var adjacentRAWPrecacheTask: Task<Void, Never>? {
        get { previewSession.adjacentPrecacheTask }
        nonmutating set { previewSession.replaceAdjacentPrecacheTask(with: newValue) }
    }

    private var editFullResTask: Task<Void, Never>? {
        get { previewSession.fullResolutionUpgradeTask }
        nonmutating set { previewSession.replaceFullResolutionUpgradeTask(with: newValue) }
    }

    private var canEditSingleImage: Bool {
        metadataViewModel.selectedCount == 1 && !metadataViewModel.isBatchEdit
    }

    private var displayImage: NSImage? {
        isShowingBefore ? sourceImage : previewRender.previewImage
    }

    /// CIImage for MetalPreviewView — shows unedited source during "before" toggle,
    /// or the lazy CIFilter chain output during editing.
    private var displayCIImage: CIImage? {
        (isShowingBefore || isMutingDevelop) ? sourceCIImage : (previewCIImage ?? sourceCIImage)
    }

    /// Image dimensions for layout calculations (stable across edits since filters
    /// don't change image size — crop is handled by the overlay, not the filter chain).
    private var currentImageSize: CGSize? {
        sourceCIImage?.extent.size ?? sourceImage?.size
    }

    private var isHDREnabled: Bool {
        metadataViewModel.editingMetadata.cameraRaw?.hdrEditMode == 1
    }

    private var saveErrorPresented: Binding<Bool> {
        Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )
    }

    // Read aliases keep presentation code compact while the coordinator owns comparison mode,
    // render output, error state, cancellation, and stale-result rejection.
    private var developComparisonTarget: ImageFile? { developComparison.imageTarget }
    private var developVersionComparisonTarget: DevelopVersionComparisonTarget? {
        developComparison.versionTarget
    }
    private var developComparisonLiveSource: ComparisonRenderedSource? {
        developComparison.liveSource
    }
    private var developVersionComparisonRightSource: ComparisonRenderedSource? {
        developComparison.versionTargetSource
    }
    private var developComparisonError: String? { developComparison.errorMessage }

    // Transitional view aliases keep presentation code readable while the coordinator remains
    // the sole owner of named-version session state and asynchronous persistence.
    private var developVersionCatalog: DevelopVersionCatalog? {
        get { developVersionSession.catalog }
        nonmutating set { developVersionSession.catalog = newValue }
    }

    private var developVersionRevision: SourceImageRevision? {
        get { developVersionSession.revision }
        nonmutating set { developVersionSession.revision = newValue }
    }

    private var developVersionStorage: DevelopVersionCatalogStorage? {
        get { developVersionSession.storage }
        nonmutating set { developVersionSession.storage = newValue }
    }

    private var developVersionPersistenceState: DevelopVersionPersistenceState {
        get { developVersionSession.persistenceState }
        nonmutating set { developVersionSession.persistenceState = newValue }
    }

    private var developVersionNotice: String? {
        get { developVersionSession.notice }
        nonmutating set { developVersionSession.notice = newValue }
    }

    private var primaryDevelopSettings: CameraRawSettings? {
        get { developVersionSession.primarySettings }
        nonmutating set { developVersionSession.primarySettings = newValue }
    }

    private var isSelectingAIMask: Bool { aiMaskSelection.isSelecting }
    private var isGeneratingAIMask: Bool { aiMaskSelection.isGenerating }
    private var replacingAIMaskID: UUID? { aiMaskSelection.replacingMaskID }

    // Transitional read aliases keep the existing presentation code compact while the
    // coordinator is the sole owner of mask-interaction state.
    private var isBrushPainting: Bool { maskInteraction.isBrushPainting }
    private var brushRadius: Double { maskInteraction.brushRadius }
    private var brushHardness: Double { maskInteraction.brushHardness }
    private var brushFlow: Double { maskInteraction.brushFlow }
    private var brushErase: Bool { maskInteraction.brushErase }
    private var maskMattePreviewMaskID: UUID? { maskInteraction.mattePreviewMaskID }

    private var editZoomScale: CGFloat { previewNavigation.zoomScale }
    private var editOffset: CGSize { previewNavigation.offset }

    // Transitional aliases keep the existing layout and input paths readable while the crop
    // coordinator remains the sole owner of this state.
    private var cropZoomScale: CGFloat {
        get { cropSession.zoomScale }
        nonmutating set { cropSession.zoomScale = newValue }
    }

    private var lastCropZoomScale: CGFloat {
        get { cropSession.lastZoomScale }
        nonmutating set { cropSession.lastZoomScale = newValue }
    }

    private var cropAspectRatio: CropAspectRatio {
        get { cropSession.aspectRatio }
        nonmutating set { cropSession.aspectRatio = newValue }
    }

    private var showCropControls: Bool {
        get { cropSession.isToolActive }
        nonmutating set { cropSession.isToolActive = newValue }
    }

    private var lockedCropImageRect: CGRect? {
        get { cropSession.lockedImageRect }
        nonmutating set { cropSession.lockedImageRect = newValue }
    }

    private var dragCropAngle: Double? { cropSession.dragAngle }
    private var dragCropRegion: NormalizedCropRegion? { cropSession.dragRegion }

    private var isShowingBefore: Bool { transientPreview.isShowingBefore }
    private var isMutingDevelop: Bool { transientPreview.isMutingDevelop }
    private var isMutingGlobal: Bool { transientPreview.isMutingGlobal }

    private var aiMaskTarget: AIMaskTarget {
        get { aiMaskSelection.target }
        nonmutating set { aiMaskSelection.target = newValue }
    }

    private var aiMaskError: String? {
        get { aiMaskSelection.errorMessage }
        nonmutating set { aiMaskSelection.errorMessage = newValue }
    }

    private var activeNamedDevelopVersion: DevelopNamedVersion? {
        developVersionSession.activeVersion
    }

    private var activeDevelopVersionLabel: String {
        activeNamedDevelopVersion?.name ?? "Primary (XMP)"
    }

    private var developVersionStatusColor: Color {
        switch developVersionPersistenceState {
        case .failed:
            .red
        case .dirty:
            .orange
        case .clean, .saved:
            .green
        case .unavailable, .loading, .saving:
            .secondary
        }
    }

    private var isDevelopVersionTransitioning: Bool {
        developVersionSession.isTransitioning
    }

    private var isDevelopComparisonActive: Bool {
        developComparison.isActive
    }

    private var hasDevelopVersionComparisonTargets: Bool {
        guard let catalog = developVersionCatalog else { return false }
        if catalog.activeVersionID != nil { return true }
        return !catalog.versions.isEmpty
    }

    private var hdrToggleBinding: Binding<Bool> {
        Binding(
            get: { metadataViewModel.editingMetadata.cameraRaw?.hdrEditMode == 1 },
            set: { newValue in
                if metadataViewModel.editingMetadata.cameraRaw == nil {
                    metadataViewModel.editingMetadata.cameraRaw = CameraRawSettings()
                }
                metadataViewModel.editingMetadata.cameraRaw?.hdrEditMode = newValue ? 1 : 0

                // Propagate to ImageFile for immediate thumbnail/fullscreen update
                if let url = selectedImageURL,
                   let index = browserViewModel.urlToImageIndex[url] {
                    if browserViewModel.images[index].cameraRawSettings == nil {
                        browserViewModel.images[index].cameraRawSettings = CameraRawSettings()
                    }
                    browserViewModel.images[index].cameraRawSettings?.hdrEditMode = newValue ? 1 : 0
                    browserViewModel.thumbnailService.invalidateEditedThumbnail(for: url)
                    // The cached edited CGImage was rendered under the old HDR state.
                    // The RAW decode itself is HDR-state independent (always full EDR
                    // headroom), so only the rendered outputs need to be dropped.
                    browserViewModel.fullScreenImageCache.invalidateEditedImage(for: url)
                }
            }
        )
    }

    private var isCropEnabled: Bool {
        metadataViewModel.editingMetadata.cameraRaw?.crop?.hasCrop ?? false
    }

    private var hasDevelopAdjustments: Bool {
        guard let cameraRaw = metadataViewModel.editingMetadata.cameraRaw else { return false }
        return cameraRaw.whiteBalance != nil
            || cameraRaw.temperature != nil
            || cameraRaw.tint != nil
            || cameraRaw.incrementalTemperature != nil
            || cameraRaw.incrementalTint != nil
            || cameraRaw.exposure2012 != nil
            || cameraRaw.contrast2012 != nil
            || cameraRaw.highlights2012 != nil
            || cameraRaw.shadows2012 != nil
            || cameraRaw.whites2012 != nil
            || cameraRaw.blacks2012 != nil
            || cameraRaw.saturation != nil
            || cameraRaw.vibrance != nil
            || cameraRaw.globalDensity != nil
            || cameraRaw.sharpness != nil
            || cameraRaw.clarity2012 != nil
            || cameraRaw.dehaze != nil
            || cameraRaw.toneCurve != nil
            || !(cameraRaw.filmEmulation?.isEmpty ?? true)
            || !(cameraRaw.localAdjustments?.isEmpty ?? true)
            || !(cameraRaw.watermarkLayers?.isEmpty ?? true)
    }

    private var selectedImageOrientation: Int {
        selectedImage?.exifOrientation ?? 1
    }

    /// Orient a freshly decoded preview to the in-memory target orientation.
    /// Decodes bake the FILE's orientation tag into the pixels, but a rotation
    /// done in the browser may not have reached the file yet (async write, or
    /// withheld entirely for C2PA-protected files) — leaving file ≠ target.
    /// `sourceCIImage`/`sourceImage` feed layout, the Metal upload, the scope,
    /// and the CIImage fallback, so they must ALL share the target frame —
    /// correcting only the texture upload leaves the fallback and layout on the
    /// file's frame and a rotated image renders stretched into the swapped canvas.
    nonisolated private static func orientedToTarget(
        ciImage: CIImage?, nsImage: NSImage?, from fileOrientation: Int, to targetOrientation: Int
    ) -> (ciImage: CIImage?, nsImage: NSImage?) {
        let correction = ImageFile.orientationCorrection(from: fileOrientation, to: targetOrientation)
        guard correction != .up else { return (ciImage, nsImage) }
        guard let orientedCI = ciImage?.oriented(correction) else { return (ciImage, nsImage) }
        var orientedNS = nsImage
        if nsImage != nil,
           let cg = CameraRawApproximation.ciContext.createCGImage(
               orientedCI, from: orientedCI.extent, format: .RGBAh,
               colorSpace: CameraRawApproximation.workingColorSpace
           ) {
            orientedNS = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        return (orientedCI, orientedNS)
    }

    /// Mask geometry is stored in the sensor (XMP) frame; the overlay and its
    /// drag interaction work on the display-oriented image. Aspect comes from
    /// the displayed image (only the ratio matters, so the downscaled preview
    /// is fine).
    private var maskDisplayAspect: Double {
        guard let size = currentImageSize, size.height > 0 else { return 1 }
        return size.width / size.height
    }

    /// Sensor (stored) → display geometry for the overlay. Two stacked
    /// transforms, applied in pipeline order: (1) EXIF orientation (the source
    /// texture is display-oriented), then (2) the crop STRAIGHTEN angle (the
    /// image view is rotated by `.rotationEffect(.degrees(-displayCropAngle))`,
    /// so the overlay must bake the same rotation). The straighten step is the
    /// identity when no angled crop is active (`displayCropAngle` == 0).
    private func maskGeometryForDisplay(_ geometry: EllipseMaskGeometry) -> EllipseMaskGeometry {
        var g = geometry
        let orientation = selectedImageOrientation
        if orientation > 1 {
            let aspect = maskDisplayAspect
            let sensorAspect = orientation >= 5 ? 1 / aspect : aspect
            g = g.transformedForDisplay(orientation: orientation, sensorAspect: sensorAspect)
        }
        return g.rotatedInDisplay(byDegrees: -displayCropAngle, aspect: maskDisplayAspect)
    }

    /// Display → sensor geometry on store: exact inverse of
    /// `maskGeometryForDisplay`, undoing the straighten first, then EXIF.
    private func maskGeometryForSensor(_ geometry: EllipseMaskGeometry) -> EllipseMaskGeometry {
        var g = geometry.rotatedInDisplay(byDegrees: displayCropAngle, aspect: maskDisplayAspect)
        let orientation = selectedImageOrientation
        if orientation > 1 {
            g = g.transformedForSensor(orientation: orientation, displayAspect: maskDisplayAspect)
        }
        return g
    }

    /// Sensor (stored) → display geometry for the watermark overlay, mirroring
    /// `maskGeometryForDisplay` — same two-stage EXIF-then-straighten transform, just for
    /// the simpler point-only `WatermarkGeometry`.
    private func watermarkGeometryForDisplay(_ geometry: WatermarkGeometry, includeStraighten: Bool = true) -> WatermarkGeometry {
        var g = geometry
        let orientation = selectedImageOrientation
        if orientation > 1 {
            g = g.transformedForDisplay(orientation: orientation)
        }
        return includeStraighten
            ? g.rotatedInDisplay(byDegrees: -displayCropAngle, aspect: maskDisplayAspect)
            : g
    }

    /// Display → sensor geometry on store: exact inverse of `watermarkGeometryForDisplay`.
    private func watermarkGeometryForSensor(_ geometry: WatermarkGeometry, includeStraighten: Bool = true) -> WatermarkGeometry {
        var g = includeStraighten
            ? geometry.rotatedInDisplay(byDegrees: displayCropAngle, aspect: maskDisplayAspect)
            : geometry
        let orientation = selectedImageOrientation
        if orientation > 1 {
            g = g.transformedForSensor(orientation: orientation)
        }
        return g
    }

    /// The library asset's decoded aspect ratio (width/height) for a watermark layer's
    /// position-handle overlay — falls back to 1 (square) if the asset went missing, matching
    /// the Metal pipeline's own missing-asset fallback (a degenerate but non-crashing handle).
    private func assetAspect(forWatermarkAssetID id: UUID) -> Double {
        WatermarkStore.shared.asset(byID: id)?.aspectRatio ?? 1
    }

    private var activeCrop: NormalizedCropRegion {
        guard let crop = metadataViewModel.editingMetadata.cameraRaw?.crop else { return .full }
        let displayCrop = crop.transformedForDisplay(orientation: selectedImageOrientation)
        return NormalizedCropRegion(
            top: displayCrop.top ?? 0,
            left: displayCrop.left ?? 0,
            bottom: displayCrop.bottom ?? 1,
            right: displayCrop.right ?? 1
        )
    }

    private var activeCropAngle: Double {
        metadataViewModel.editingMetadata.cameraRaw?.crop?.angle ?? 0
    }

    /// During rotation drag, prefer the local @State over the ViewModel
    /// to avoid @Observable cascade while providing real-time visual feedback.
    private var displayCropAngle: Double {
        dragCropAngle ?? activeCropAngle
    }

    private var displayCrop: NormalizedCropRegion {
        dragCropRegion ?? activeCrop
    }

    private var sourceAspectRatio: Double {
        guard let size = sourceImage?.size, size.width > 0, size.height > 0 else { return 1.5 }
        return size.width / size.height
    }

    private func watermarkCropImageSize(from imageSize: CGSize) -> CGSize {
        CGSize(
            width: max(1, CGFloat(displayCrop.width) * imageSize.width),
            height: max(1, CGFloat(displayCrop.height) * imageSize.height)
        )
    }

    private func watermarkCropContentRect(in containerSize: CGSize, imageSize: CGSize) -> CGRect {
        let cropSize = watermarkCropImageSize(from: imageSize)
        let handlePadding = EditCropPreviewFraming.handlePadding(isCropToolActive: false)
        let availW = max(containerSize.width - handlePadding * 2, 1)
        let availH = max(containerSize.height - handlePadding * 2, 1)
        let fitScale = min(availW / cropSize.width, availH / cropSize.height) * max(editZoomScale, 0.0001)
        let width = cropSize.width * fitScale
        let height = cropSize.height * fitScale
        return CGRect(
            x: (containerSize.width - width) * 0.5,
            y: (containerSize.height - height) * 0.5,
            width: width,
            height: height
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                developPreviewArea
                Divider()
                controlsPane
                    .frame(width: 330)
                    .background(Color(nsColor: .underPageBackgroundColor))
            }
            Divider()
            filmstrip
        }
        .background(
            DisplayGamutObserver(
                scopeViewModel: scopeViewModel,
                settingsViewModel: settingsViewModel,
                isHDR: isHDREnabled
            )
        )
        .focusable()
        .focused($isWorkspaceFocused)
        .focusEffectDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Develop workspace")
        .accessibilityIdentifier("develop.workspace")
        .onTapGesture {
            isWorkspaceFocused = true
        }
        .onAppear {
            handleEditWorkspaceAppear()
        }
        .onDisappear {
            handleEditWorkspaceDisappear()
        }
        .onChange(of: browserViewModel.selectedImageIDs) { _, _ in
            ensureAtLeastOneSelected()
        }
        .onChange(of: selectedImageURL) { oldURL, newURL in
            if oldURL != newURL {
                cancelColorLUTImport()
                importingLUTForLayerID = nil
                closeDevelopComparison()
                handleDevelopVersionImageChange(from: oldURL, to: newURL)
            }
            editLog.info("[\(newURL?.lastPathComponent ?? "nil")] loadSelectedImagePreview triggered by: onChange(selectedImageURL) old=\(oldURL?.lastPathComponent ?? "nil")")
            loadSelectedImagePreview()
        }
        .onChange(of: metadataViewModel.editingMetadata.cameraRaw) { _, _ in
            renderPreview()
        }
        .onChange(of: editZoomScale) { _, _ in
            // Zooming past fit-view runs the screen-res texture out of detail — upgrade to full-res.
            loadFullResEditTextureIfNeeded()
        }
        .onChange(of: metadataViewModel.metadataLoadGeneration) { _, _ in
            // Re-apply HDR auto-enable after metadata load completes.
            // Now safe to include the "Render RAW as HDR" preference because
            // any XMP hdrEditMode value has been loaded and takes priority.
            autoEnableHDRIfNeeded(includeRawPreference: true)
            installLoadedDevelopVersionIfReady()
            renderPreview()
        }
        .onChange(of: isDraggingEditSlider) { wasDragging, isDragging in
            NotificationCenter.default.post(
                name: .editSliderDragStateChanged,
                object: nil,
                userInfo: ["isDragging": isDragging]
            )
            if isDragging, !wasDragging {
                metalCoordinator.startContinuousRendering()
                cleanFeedController.setFeedContinuousRendering(true)
            }
            if wasDragging, !isDragging {
                // Commit crop drag to ViewModel before clearing overlay state
                let cropDrag = cropSession.finishInteraction()
                if let angle = cropDrag.angle {
                    updateCropAngle(angle, commit: false)
                }
                metalCoordinator.stopContinuousRendering()
                cleanFeedController.setFeedContinuousRendering(false)
                scopeThrottleTask?.cancel()
                scopeThrottleTask = nil
                renderPreview()
            }
        }
        .onChange(of: selectedImage?.exifOrientation) { oldVal, newVal in
            // Same image rotated in-app: rotate the retained source by the known delta
            // rather than re-decoding. A re-decode reads the file's just-rewritten EXIF
            // tag, which ImageIO can serve inconsistently (new pixels + stale reported
            // orientation) so the corrective rotation double-applies — the preview shows
            // 180° while the file only rotated 90°. Rotating the already-correct source
            // avoids the file round-trip entirely and is always a single, exact step.
            if let url = selectedImageURL, sourceCIImage != nil,
               let from = previewSession.loadedOrientation(for: url), let newVal, from != newVal,
               ImageFile.orientationCorrection(from: from, to: newVal) != .up {
                editLog.info("[\(url.lastPathComponent)] in-place rotate source \(from) → \(newVal)")
                rotateSourceInPlace(from: from, to: newVal)
                return
            }
            editLog.info("[\(selectedImageURL?.lastPathComponent ?? "nil")] loadSelectedImagePreview triggered by: onChange(exifOrientation) \(oldVal ?? 0) → \(newVal ?? 0)")
            loadSelectedImagePreview()
        }
        .onChange(of: isShowingBefore) { _, _ in
            // Re-sync viewport: crop mode uses identity viewport, but the "before"
            // view falls to the normal-fit path and needs a proper viewport.
            syncViewportToMetal()
            renderPreview()
        }
        .onChange(of: isMutingDevelop) { _, _ in
            syncViewportToMetal()
            renderPreview()
        }
        .onChange(of: selectedLayer) { _, _ in
            clearMaskMattePreview()
            // Clear Metal overlay — the AppKit MaskOverlayNSView handles
            // static display with interactive handles. Metal overlay is only used
            // during active mask drags for real-time feedback.
            metalPipeline?.updateOverlayParams(geometry: nil, visible: false)
            // Leaving a brush layer (e.g. after deleting one) exits paint mode, so the brush
            // controls don't linger on Global or radial layers. Selecting a brush layer keeps it.
            maskInteraction.selectedLayerDidChange(isBrush: selectedMaskIsBrush)
            aiMaskSelection.cancelSelectionIfIdle()
            if let id = selectedMaskID,
               let target = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments?
                .first(where: { $0.id == id })?.aiMask?.resolvedTarget {
                aiMaskSelection.adoptTarget(target)
            }
            syncMaskOverlayTarget()
            metalCoordinator.requestRedraw()
        }
        .onChange(of: cleanFeedController.isEnabled) { _, enabled in
            // Feed toggled while editing — connect/disconnect the live mirror.
            updateCleanFeedMirror(enabled: enabled)
        }
        .onChange(of: scopeViewModel.showClippedGamut) { _, _ in
            updateGamutClipMode()
        }
        .onChange(of: scopeViewModel.targetGamut) { _, _ in
            updateGamutClipMode()
        }
        .onChange(of: commandRouter.latestDelivery) { _, delivery in
            guard let delivery else { return }
            switch delivery.command {
            case .addNewMask:
                guard canEditSingleImage else { return }
                addNewMask(center: maskCenterUnderCursor())
            case .removeOrResetSelectedEditLayer:
                guard canEditSingleImage else { return }
                removeOrResetSelectedEditLayer()
            case .toggleHDR:
                guard canEditSingleImage else { return }
                hdrToggleBinding.wrappedValue.toggle()
                // Auto-switch soft-proof target gamut and display gamut from format settings
                if scopeViewModel.showClippedGamut {
                    scopeViewModel.targetGamut = isHDREnabled
                        ? settingsViewModel.exportColorGamutHDR
                        : settingsViewModel.exportColorGamutSDR
                }
                // Refresh gamut clip pipeline so HDR flag is immediately applied/cleared
                updateGamutClipMode()
            case .applyDevelopTemplate(let template):
                guard canEditSingleImage else { return }
                applyDevelopTemplate(template)
            case .openFolder, .openRecentFolder, .setRating, .setLabel,
                 .renderSelected, .advancedExportSelected, .renderAll,
                 .saveAsJPEG, .saveAsPNG, .archiveRAW,
                 .selectPreviousImage, .selectNextImage,
                 .rotateClockwise, .rotateCounterclockwise,
                 .renameSelected, .duplicateSelected,
                 .resetAllEdits, .removeAllIPTC,
                 .showImport, .backupEditedFiles, .backupEditedFilesForFolder,
                 .openInInternalEditor, .openInExternalEditor,
                 .deleteSelected, .moveRejectedToFolder,
                 .setScopeMode, .toggleGamutClipping,
                 .uploadSelected, .uploadAll,
                 .processVariablesSelected, .processVariablesAll,
                 .showTemplatePalette, .applyTemplateShortcut,
                 .writeAllPendingMetadata, .openCaptionWorkspace,
                 .renderAndSignSelected, .copyIPTCMetadata, .pasteIPTCMetadata,
                 .showVariableReference, .showRawMetadata, .showStructuredKeywords,
                 .showKnownPeopleDatabase, .registerOpenFolderForSidebar,
                 .restoreCaptionEditorFocus:
                break
            }
        }
        .overlay(alignment: .top) {
            if let feedback = copyPasteFeedback {
                Text(feedback)
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.7), in: Capsule())
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: copyPasteFeedback)
        .modifier(EditWorkspaceExportFailureAlertModifier(saveError: $saveError))
        .modifier(DevelopVersionDialogsModifier(
            nameAction: $developVersionNameAction,
            nameDraft: $developVersionNameDraft,
            pendingDeleteID: $developVersionPendingDeleteID,
            pendingPromotionID: $developVersionPendingPromotionID,
            promotionMessage: developVersionPromotionMessage,
            performNameAction: performDevelopVersionNameAction,
            deleteVersion: deleteDevelopVersion,
            promoteVersion: promoteDevelopVersion
        ))
    }

    @ViewBuilder
    private var developPreviewArea: some View {
        if let target = developComparisonTarget,
           let current = selectedImage {
            if let developComparisonLiveSource {
                ComparisonWorkspaceView(
                    images: [current, target],
                    navigationImages: browserViewModel.visibleImages,
                    availableImages: browserViewModel.sortedImages.filter(\.isImageFile),
                    fullScreenImageCache: browserViewModel.fullScreenImageCache,
                    origin: .develop,
                    initialLeftRepresentation: nil,
                    liveSource: developComparisonLiveSource,
                    initialRightSource: nil,
                    allowsSourceReplacement: true,
                    allowsDeletion: false,
                    onFocusedImageChange: { _ in },
                    onRequestDelete: { _ in },
                    onClose: { _, _ in closeDevelopComparison() }
                )
            } else if let developComparisonError {
                ContentUnavailableView {
                    Label("Comparison Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(developComparisonError)
                } actions: {
                    Button("Try Again") { scheduleDevelopComparisonRender() }
                    Button("Close Compare") { closeDevelopComparison() }
                }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Preparing the live Develop comparison…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Self.previewBackground)
            }
        } else if developVersionComparisonTarget != nil,
                  let current = selectedImage {
            if let developComparisonLiveSource,
               let developVersionComparisonRightSource {
                ComparisonWorkspaceView(
                    images: [current, current],
                    navigationImages: [current],
                    availableImages: [current],
                    fullScreenImageCache: browserViewModel.fullScreenImageCache,
                    origin: .develop,
                    initialLeftRepresentation: nil,
                    liveSource: developComparisonLiveSource,
                    initialRightSource: developVersionComparisonRightSource,
                    allowsSourceReplacement: false,
                    allowsDeletion: false,
                    onFocusedImageChange: { _ in },
                    onRequestDelete: { _ in },
                    onClose: { _, _ in closeDevelopComparison() }
                )
            } else if let developComparisonError {
                ContentUnavailableView {
                    Label("Version Comparison Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(developComparisonError)
                } actions: {
                    Button("Try Again") { scheduleDevelopComparisonRender() }
                    Button("Close Compare") { closeDevelopComparison() }
                }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Preparing the Develop version comparison…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Self.previewBackground)
            }
        } else {
            previewPane
        }
    }

    private var previewPane: some View {
        GeometryReader { geometry in
            ZStack {
                Self.previewBackground

                if let imageSize = currentImageSize, displayCIImage != nil {
                    if (showCropControls || isCropEnabled), !isShowingBefore {
                        // Crop-centered: image scales/positions so crop fills view
                        let zoom = showCropControls ? cropZoomScale : 1.0
                        let computedImageRect = cropFittedImageRect(
                            in: geometry.size,
                            imageSize: imageSize,
                            crop: displayCrop,
                            angleDegrees: displayCropAngle,
                            zoom: zoom,
                            handlePadding: EditCropPreviewFraming.handlePadding(
                                isCropToolActive: showCropControls
                            )
                        )
                        // Lock image rect during crop interaction to prevent
                        // image rescaling while the overlay stays stable
                        let imageRect = lockedCropImageRect ?? computedImageRect

                        if showCropControls {
                            // Crop editing mode: zoom via cropZoomScale only
                            MetalPreviewView(
                                ciImage: displayCIImage,
                                isHDR: isHDREnabled && !isShowingBefore,
                                metalPipeline: metalPipeline,
                                useComputeShader: !isShowingBefore && metalPipeline?.hasSourceTexture == true,
                                useNearestNeighbor: scaling.useNearestNeighbor,
                                coordinator: metalCoordinator
                            )
                                .frame(width: imageRect.width, height: imageRect.height)
                                .rotationEffect(.degrees(-displayCropAngle))
                                .position(x: imageRect.midX, y: imageRect.midY)

                            if canEditSingleImage {
                                CropOverlayView(
                                    imageRect: imageRect,
                                    viewSize: geometry.size,
                                    crop: displayCrop,
                                    angle: displayCropAngle,
                                    aspectRatio: cropAspectRatio,
                                    imageAspectRatio: sourceAspectRatio,
                                    onChange: { newCrop in
                                        if lockedCropImageRect == nil {
                                            lockedCropImageRect = computedImageRect
                                        }
                                        // Coordinator-local state only — bypass metadata during
                                        // drag to avoid an expensive observation cascade.
                                        cropSession.updateCropDrag(newCrop)
                                    },
                                    onAngleChange: { newAngle in
                                        if lockedCropImageRect == nil {
                                            lockedCropImageRect = computedImageRect
                                        }
                                        let clampedAngle = min(max(newAngle, -45), 45)
                                        let currentRegion = dragCropRegion ?? activeCrop
                                        let ar = sourceAspectRatio
                                        // The crop keeps its (upright) dimensions; only re-fit
                                        // its position/scale to the new rotated image bounds.
                                        let fitted = currentRegion
                                            .centerClampedForRotation(angleDegrees: clampedAngle, aspectRatio: ar)
                                            .fittingRotated(angleDegrees: clampedAngle, aspectRatio: ar)
                                        cropSession.updateAngleDrag(clampedAngle, region: fitted)
                                    },
                                    onCommit: {
                                        // Commit accumulated drag state to ViewModel
                                        let cropDrag = cropSession.finishInteraction()
                                        if let region = cropDrag.region {
                                            updateCrop(region, commit: false)
                                        }
                                        if let angle = cropDrag.angle {
                                            updateCropAngle(angle, commit: false)
                                        }
                                        commitEditAdjustments()
                                    },
                                    onAspectRatioOverride: { newRatio in
                                        cropAspectRatio = newRatio
                                    }
                                )
                            }
                        } else {
                            // Crop applied, normal editing: support zoom/pan
                            let cropViewport = editCropViewport(in: geometry.size, imageSize: metalImageSize ?? imageSize)
                            ZStack {
                                MetalPreviewView(
                                    ciImage: displayCIImage,
                                    isHDR: isHDREnabled && !isShowingBefore,
                                    metalPipeline: metalPipeline,
                                    useComputeShader: !isShowingBefore && metalPipeline?.hasSourceTexture == true,
                                    useNearestNeighbor: scaling.useNearestNeighbor,
                                    coordinator: metalCoordinator
                                )
                                    .frame(width: geometry.size.width, height: geometry.size.height)

                                // Ellipse mask overlay (crop-applied path) — ellipse masks only,
                                // suppressed while the brush tool owns the mouse.
                                if let maskIdx = selectedMaskIndex,
                                   let masks = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments,
                                   maskIdx < masks.count,
                                   !masks[maskIdx].isFullFrame,
                                   masks[maskIdx].brush == nil,
                                   masks[maskIdx].aiMask == nil,
                                   showsMaskOutlines,
                                   maskMattePreviewMaskID == nil,
                                   !isBrushPainting,
                                   !isShowingBefore {
                                    MaskOverlayRepresentable(
                                        viewportOrigin: cropViewport.origin,
                                        viewportSize: cropViewport.size,
                                        viewSize: geometry.size,
                                        geometry: maskGeometryForDisplay(dragMaskGeometry ?? masks[maskIdx].geometry),
                                        inverted: masks[maskIdx].inverted,
                                        onStart: {
                                            isDraggingMask = true
                                            isDraggingEditSlider = true
                                        },
                                        onChange: { newGeometry in
                                            // The overlay drags in the display frame; store sensor-frame.
                                            let sensorGeometry = maskGeometryForSensor(newGeometry)
                                            dragMaskGeometry = sensorGeometry
                                            if let pipeline = metalPipeline, pipeline.hasSourceTexture {
                                                var settings = metadataViewModel.editingMetadata.cameraRaw ?? CameraRawSettings()
                                                settings.localAdjustments?[maskIdx].geometry = sensorGeometry
                                                pipeline.updateParams(settingsForPipeline(settings))
                                            }
                                        },
                                        onCommit: {
                                            if let finalGeo = dragMaskGeometry {
                                                updateCameraRaw { cameraRaw in
                                                    cameraRaw.localAdjustments?[maskIdx].geometry = finalGeo
                                                }
                                                dragMaskGeometry = nil
                                            }
                                            isDraggingMask = false
                                            isDraggingEditSlider = false
                                            commitEditAdjustments()
                                        }
                                    )
                                    .allowsHitTesting(!isSpaceHandToolActive)
                                }

                                // Watermark position handle (crop-applied path).
                                if let wmIdx = selectedWatermarkIndex,
                                   let layers = metadataViewModel.editingMetadata.cameraRaw?.watermarkLayers,
                                   wmIdx < layers.count,
                                   !isShowingBefore, let imgSize = currentImageSize {
                                    let watermarkImageSize = watermarkCropImageSize(from: imgSize)
                                    WatermarkOverlayRepresentable(
                                        viewportOrigin: cropViewport.origin,
                                        viewportSize: cropViewport.size,
                                        viewSize: geometry.size,
                                        geometry: watermarkGeometryForDisplay(
                                            dragWatermarkGeometry ?? layers[wmIdx].geometry,
                                            includeStraighten: false
                                        ),
                                        assetAspect: assetAspect(forWatermarkAssetID: layers[wmIdx].libraryAssetID),
                                        imageSize: watermarkImageSize,
                                        contentRect: watermarkCropContentRect(in: geometry.size, imageSize: imgSize),
                                        onStart: { isDraggingEditSlider = true },
                                        onChange: { newGeometry in
                                            let sensorGeometry = watermarkGeometryForSensor(newGeometry, includeStraighten: false)
                                            dragWatermarkGeometry = sensorGeometry
                                            if let pipeline = metalPipeline, pipeline.hasSourceTexture {
                                                var settings = metadataViewModel.editingMetadata.cameraRaw ?? CameraRawSettings()
                                                settings.watermarkLayers?[wmIdx].geometry = sensorGeometry
                                                pipeline.updateParams(settingsForPipeline(settings))
                                            }
                                        },
                                        onCommit: {
                                            if let finalGeo = dragWatermarkGeometry {
                                                updateCameraRaw { cameraRaw in
                                                    cameraRaw.watermarkLayers?[wmIdx].geometry = finalGeo
                                                }
                                                dragWatermarkGeometry = nil
                                            }
                                            isDraggingEditSlider = false
                                            commitEditAdjustments()
                                        }
                                    )
                                    .allowsHitTesting(!isSpaceHandToolActive)
                                }

                                // White-balance eyedropper over the crop-framed preview.
                                if isPickingWhiteBalance, !isShowingBefore {
                                    WhiteBalancePickOverlay(
                                        marquee: $wbPickDragRect,
                                        probe: { rect in
                                            probeLinearRGB(
                                                forPaneRect: rect, paneSize: geometry.size,
                                                viewportOrigin: cropViewport.origin, viewportSize: cropViewport.size
                                            )
                                        },
                                        onPick: { rect in
                                            performWhiteBalancePick(
                                                inPaneRect: rect, paneSize: geometry.size,
                                                viewportOrigin: cropViewport.origin, viewportSize: cropViewport.size
                                            )
                                        }
                                    )
                                    .frame(width: geometry.size.width, height: geometry.size.height)
                                    .allowsHitTesting(!isSpaceHandToolActive)
                                }

                                // Freeform brush paint overlay (crop-applied path).
                                brushOverlay(viewportOrigin: cropViewport.origin, viewportSize: cropViewport.size, viewSize: geometry.size)
                                    .allowsHitTesting(!isSpaceHandToolActive)

                                aiMaskSelectionOverlay(
                                    viewportOrigin: cropViewport.origin,
                                    viewportSize: cropViewport.size,
                                    viewSize: geometry.size
                                )
                                .allowsHitTesting(!isSpaceHandToolActive)
                            }
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            // The normal pan gesture yields to both brush painting and the
                            // temporary Space hand-tool surface installed above all tools.
                            .gesture(editPanGesture(in: geometry.size, imageSize: geometry.size),
                                     including: (isBrushPainting || isSelectingAIMask || isSpaceHandToolActive) ? .subviews : .all)
                        }
                    } else {
                        // Normal fit: Metal viewport handles zoom/pan and letterboxing
                        let vpOrigin = currentViewportOrigin
                        let vpSize = currentViewportSize

                        ZStack {
                            MetalPreviewView(
                                ciImage: displayCIImage,
                                isHDR: isHDREnabled && !isShowingBefore,
                                metalPipeline: metalPipeline,
                                useComputeShader: !isShowingBefore && metalPipeline?.hasSourceTexture == true,
                                useNearestNeighbor: scaling.useNearestNeighbor,
                                coordinator: metalCoordinator
                            )
                                .frame(width: geometry.size.width, height: geometry.size.height)

                            // Ellipse mask overlay — only for ellipse masks, and not while the
                            // brush tool is active (its overlay owns the mouse then).
                            if let maskIdx = selectedMaskIndex,
                               let masks = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments,
                               maskIdx < masks.count,
                               !masks[maskIdx].isFullFrame,
                               masks[maskIdx].brush == nil,
                               masks[maskIdx].aiMask == nil,
                               showsMaskOutlines,
                               maskMattePreviewMaskID == nil,
                               !isBrushPainting,
                               !isShowingBefore {
                                MaskOverlayRepresentable(
                                    viewportOrigin: vpOrigin,
                                    viewportSize: vpSize,
                                    viewSize: geometry.size,
                                    geometry: maskGeometryForDisplay(dragMaskGeometry ?? masks[maskIdx].geometry),
                                    inverted: masks[maskIdx].inverted,
                                    onStart: {
                                        isDraggingMask = true
                                        isDraggingEditSlider = true
                                    },
                                    onChange: { newGeometry in
                                        // The overlay drags in the display frame; store sensor-frame.
                                        // Track drag geometry locally — bypass ViewModel
                                        let sensorGeometry = maskGeometryForSensor(newGeometry)
                                        dragMaskGeometry = sensorGeometry
                                        // Direct Metal update for real-time preview + scope
                                        if let pipeline = metalPipeline, pipeline.hasSourceTexture {
                                            var settings = metadataViewModel.editingMetadata.cameraRaw ?? CameraRawSettings()
                                            settings.localAdjustments?[maskIdx].geometry = sensorGeometry
                                            pipeline.updateParams(settingsForPipeline(settings))
                                        }
                                    },
                                    onCommit: {
                                        // Commit final geometry to ViewModel
                                        if let finalGeo = dragMaskGeometry {
                                            updateCameraRaw { cameraRaw in
                                                cameraRaw.localAdjustments?[maskIdx].geometry = finalGeo
                                            }
                                            dragMaskGeometry = nil
                                        }
                                        isDraggingMask = false
                                        isDraggingEditSlider = false
                                        commitEditAdjustments()
                                    }
                                )
                                .allowsHitTesting(!isSpaceHandToolActive)
                            }

                            // Watermark position handle.
                            if let wmIdx = selectedWatermarkIndex,
                               let layers = metadataViewModel.editingMetadata.cameraRaw?.watermarkLayers,
                               wmIdx < layers.count,
                               !isShowingBefore, let imgSize = currentImageSize {
                                WatermarkOverlayRepresentable(
                                    viewportOrigin: vpOrigin,
                                    viewportSize: vpSize,
                                    viewSize: geometry.size,
                                    geometry: watermarkGeometryForDisplay(dragWatermarkGeometry ?? layers[wmIdx].geometry),
                                    assetAspect: assetAspect(forWatermarkAssetID: layers[wmIdx].libraryAssetID),
                                    imageSize: imgSize,
                                    contentRect: nil,
                                    onStart: { isDraggingEditSlider = true },
                                    onChange: { newGeometry in
                                        let sensorGeometry = watermarkGeometryForSensor(newGeometry)
                                        dragWatermarkGeometry = sensorGeometry
                                        if let pipeline = metalPipeline, pipeline.hasSourceTexture {
                                            var settings = metadataViewModel.editingMetadata.cameraRaw ?? CameraRawSettings()
                                            settings.watermarkLayers?[wmIdx].geometry = sensorGeometry
                                            pipeline.updateParams(settingsForPipeline(settings))
                                        }
                                    },
                                    onCommit: {
                                        if let finalGeo = dragWatermarkGeometry {
                                            updateCameraRaw { cameraRaw in
                                                cameraRaw.watermarkLayers?[wmIdx].geometry = finalGeo
                                            }
                                            dragWatermarkGeometry = nil
                                        }
                                        isDraggingEditSlider = false
                                        commitEditAdjustments()
                                    }
                                )
                                .allowsHitTesting(!isSpaceHandToolActive)
                            }

                            // White-balance eyedropper: click a neutral grey or drag a
                            // rectangle to average an area, then solve for temperature/tint.
                            if isPickingWhiteBalance, !isShowingBefore {
                                WhiteBalancePickOverlay(
                                    marquee: $wbPickDragRect,
                                    probe: { rect in
                                        probeLinearRGB(
                                            forPaneRect: rect, paneSize: geometry.size,
                                            viewportOrigin: vpOrigin, viewportSize: vpSize
                                        )
                                    },
                                    onPick: { rect in
                                        performWhiteBalancePick(
                                            inPaneRect: rect, paneSize: geometry.size,
                                            viewportOrigin: vpOrigin, viewportSize: vpSize
                                        )
                                    }
                                )
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .allowsHitTesting(!isSpaceHandToolActive)
                            }

                            // Freeform brush paint overlay (bare "B").
                            brushOverlay(viewportOrigin: vpOrigin, viewportSize: vpSize, viewSize: geometry.size)
                                .allowsHitTesting(!isSpaceHandToolActive)

                            aiMaskSelectionOverlay(
                                viewportOrigin: vpOrigin,
                                viewportSize: vpSize,
                                viewSize: geometry.size
                            )
                            .allowsHitTesting(!isSpaceHandToolActive)
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        // The normal pan gesture yields to both brush painting and the
                        // temporary Space hand-tool surface installed above all tools.
                        .gesture(editPanGesture(in: geometry.size, imageSize: imageSize),
                                 including: (isBrushPainting || isSelectingAIMask || isSpaceHandToolActive) ? .subviews : .all)
                    }
                } else if isLoadingPreview {
                    ProgressView("Loading preview...")
                        .controlSize(.large)
                } else {
                    ContentUnavailableView(
                        "No image selected",
                        systemImage: "photo",
                        description: Text("Choose an image from the filmstrip to start editing.")
                    )
                }

                if showCropControls, canEditSingleImage {
                    VStack {
                        Spacer()
                        cropPreviewToolbar
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                    }
                }

                // Full-resolution decode indicator for RAW files
                if isDecodingFullResolution {
                    VStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Decoding RAW...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }

                // Zoom percentage indicator
                if editZoomScale > 1.01 {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Text("\(Int(editZoomScale * 100))%")
                                .font(.caption.monospacedDigit().bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.black.opacity(0.6), in: Capsule())
                                .padding(8)
                        }
                    }
                }

                // Space temporarily owns all pointer input over the preview. Keeping this
                // surface above the AppKit brush/mask/watermark overlays makes panning work
                // consistently without changing or dismissing the selected editing tool.
                if isSpaceHandToolActive, !showCropControls {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            editHandPanGesture(
                                in: geometry.size,
                                imageSize: currentImageSize ?? geometry.size
                            )
                        )
                }
            }
            .environment(\.suppressesEditCursorOverlays, isSpaceHandToolActive)
            .clipped()
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            previewPaneFrame = proxy.frame(in: .global)
                            syncViewportToMetal()
                        }
                        .onChange(of: proxy.size) { _, _ in
                            previewPaneFrame = proxy.frame(in: .global)
                            syncViewportToMetal()
                        }
                }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    isCursorOverPreview = true
                    if isSpaceHandToolActive { NSCursor.openHand.set() }
                case .ended:
                    isCursorOverPreview = false
                    if isSpaceHandToolActive { NSCursor.arrow.set() }
                }
            }
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        if showCropControls {
                            let dampened = 1.0 + (value.magnification - 1.0) * 0.4
                            cropZoomScale = (lastCropZoomScale * dampened).clamped(to: 0.25...3.0)
                        } else {
                            previewNavigation.updateMagnification(value.magnification)
                            syncViewportToMetal()
                        }
                    }
                    .onEnded { _ in
                        if showCropControls {
                            lastCropZoomScale = cropZoomScale
                        } else {
                            previewNavigation.finishMagnification()
                            if editZoomScale > 1.0, isCropEnabled, !isShowingBefore {
                                constrainEditOffset(in: geometry.size, imageSize: geometry.size)
                            }
                            syncViewportToMetal()
                        }
                    }
            )
            .onAppear {
                scrollEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                    guard isCursorOverPreview else { return event }
                    // Only handle direct scroll input, ignore momentum to avoid drift
                    guard event.phase != [] || event.momentumPhase == [] else { return event }
                    let delta = event.scrollingDeltaY
                    guard abs(delta) > 0.01 else { return event }

                    if showCropControls {
                        let zoomFactor = 1.0 + (delta * 0.005)
                        let newScale = (cropZoomScale * zoomFactor).clamped(to: 0.25...3.0)
                        cropZoomScale = newScale
                        lastCropZoomScale = newScale
                    } else {
                        handleEditScrollZoom(delta: delta, event: event)
                    }
                    return nil
                }
            }
            .onDisappear {
                if let monitor = scrollEventMonitor {
                    NSEvent.removeMonitor(monitor)
                    scrollEventMonitor = nil
                }
            }
        }
    }

    private var controlsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Button {
                        requestEditWorkspaceExit()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Exit Edit View (Esc)")
                    Spacer()
                    if canEditSingleImage {
                        Menu {
                            if let target = defaultDevelopComparisonTarget {
                                Button("Compare with \(target.filename)") {
                                    openDevelopComparison(with: target)
                                }
                            } else {
                                Text("No other supported image is available")
                            }

                            Divider()
                            Text("Or right-click an image in the filmstrip")

                            if isDevelopComparisonActive {
                                Divider()
                                Button("Close Comparison") {
                                    closeDevelopComparison()
                                }
                            }
                        } label: {
                            Image(systemName: "rectangle.split.2x1")
                                .font(.system(size: 11, weight: isDevelopComparisonActive ? .semibold : .regular))
                                .foregroundStyle(isDevelopComparisonActive ? Color.accentColor : Color.secondary)
                                .padding(4)
                                .background(
                                    isDevelopComparisonActive ? Color.accentColor.opacity(0.16) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 4)
                                )
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .disabled(defaultDevelopComparisonTarget == nil && !isDevelopComparisonActive)
                        .help(isDevelopComparisonActive ? "Develop comparison options" : "Compare the live edit with another image")
                        .accessibilityLabel("Develop comparison")

                        Button {
                            saveCurrentRenderedImage()
                        } label: {
                            Image(systemName: isSavingRenderedJPEG ? "hourglass" : "square.and.arrow.down")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(selectedImageURL == nil || isSavingRenderedJPEG)
                        .help(saveButtonLabel)
                        .accessibilityLabel(saveButtonLabel)

                        Button {
                            toggleCropControls()
                        } label: {
                            Image(systemName: "crop")
                                .font(.system(size: 11, weight: showCropControls ? .semibold : .regular))
                                .foregroundStyle(showCropControls ? Color.accentColor : Color.secondary)
                                .padding(4)
                                .background(
                                    showCropControls ? Color.accentColor.opacity(0.16) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 4)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(showCropControls ? "Finish Crop (C)" : "Crop (C)")
                        .accessibilityLabel(showCropControls ? "Finish Crop" : "Crop")

                        Button {
                            editUndoManager.undo()
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(!editUndoManager.canUndo)
                        .help("Undo (⌘Z)")

                        Button {
                            editUndoManager.redo()
                        } label: {
                            Image(systemName: "arrow.uturn.forward")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(!editUndoManager.canRedo)
                        .help("Redo (⇧⌘Z)")
                    }
                    if canEditSingleImage, hasDevelopAdjustments {
                        Button {
                            resetDevelopAdjustmentsKeepingCrop()
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Reset develop adjustments (keep crop)")
                    }
                }

                if canEditSingleImage {
                    developVersionSelector
                        .padding(.vertical, 6)
                }

                if canEditSingleImage {
                    if showCropControls {
                        cropInspectorControls
                    } else {
                        if metadataViewModel.hasEmbeddedCropNotLoaded {
                            Button {
                                metadataViewModel.importEmbeddedCrop()
                                if !showCropControls {
                                    toggleCropControls()
                                }
                                commitEditAdjustments()
                            } label: {
                                Label("Load Embedded Crop", systemImage: "square.and.arrow.down")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.orange)
                            .help("Load crop from embedded image metadata")
                        }

                        // ── Mask Selector ──
                        maskSelectorBar

                        if isSelectingAIMask {
                            aiMaskToolbar(id: replacingAIMaskID)
                        } else if isBrushPainting || selectedMaskIsBrush {
                            brushToolbar
                        } else if selectedMaskIsAI, let id = selectedMaskID {
                            aiMaskToolbar(id: id)
                        } else if !selectedMaskIsFullFrame,
                                  let idx = selectedMaskIndex, let id = selectedMaskID {
                            analyticMaskToolbar(index: idx, id: id)
                        }

                        if selectedColorTransformIndex != nil {
                            colorTransformLayerControls
                        } else if selectedMaskIndex != nil {
                            maskAdjustmentSliders
                        } else if selectedWatermarkIndex != nil {
                            watermarkLayerControls
                        } else {
                            globalAdjustmentSliders
                        }
                    }

                } else {
                    Text("Select exactly one image to edit.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 14)
            .padding(.vertical, 14)
            // macOS uses a substantially wider, permanently visible scroller when
            // “Show scroll bars: Always” is enabled (common on desktop Macs without a
            // trackpad). ScrollView overlays that scroller, so reserve enough trailing
            // space to keep slider values, reset buttons, and picker edges unobscured.
            .padding(.trailing, 28)
            .disabled(isDecodingFullResolution || isDevelopVersionTransitioning)
            .opacity(isDecodingFullResolution || isDevelopVersionTransitioning ? 0.6 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isDecodingFullResolution)
            .animation(.easeInOut(duration: 0.15), value: isDevelopVersionTransitioning)
        }
    }

    private var developVersionSelector: some View {
        let availableWatermarkIDs = Set(watermarkStore.allAssets().map(\.id))
        let referencedWatermarkIDs = Set(
            (developVersionCatalog?.versions ?? []).flatMap { version in
                version.snapshot.dependencyManifest.compactMap { dependency in
                    dependency.kind == .watermark ? UUID(uuidString: dependency.identifier) : nil
                }
            }
        )
        let watermarkPairs: [(UUID, Data)] = referencedWatermarkIDs.compactMap {
            id -> (UUID, Data)? in
            guard availableWatermarkIDs.contains(id) else { return nil }
            return watermarkStore.imageData(forAssetID: id).map { (id, $0) }
        }
        let watermarkData = Dictionary(uniqueKeysWithValues: watermarkPairs)

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("Version")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Menu {
                    Button {
                        switchDevelopVersion(to: nil)
                    } label: {
                        Label(
                            "Primary (XMP)",
                            systemImage: developVersionCatalog?.activeVersionID == nil
                                ? "checkmark" : "photo"
                        )
                    }

                    if let catalog = developVersionCatalog, !catalog.versions.isEmpty {
                        Divider()
                        ForEach(catalog.versions) { version in
                            Button {
                                switchDevelopVersion(to: version.id)
                            } label: {
                                Label(
                                    developVersionMenuLabel(
                                        for: version,
                                        isDefault: catalog.defaultVersionID == version.id,
                                        watermarkData: watermarkData
                                    ),
                                    systemImage: developVersionMenuIcon(
                                        for: version,
                                        isActive: catalog.activeVersionID == version.id,
                                        watermarkData: watermarkData
                                    )
                                )
                            }
                        }
                    }

                    Divider()
                    Button("New Version from Current…", systemImage: "plus") {
                        beginDevelopVersionNameAction(.create)
                    }

                    if let activeVersion = activeNamedDevelopVersion {
                        Button("Duplicate…", systemImage: "plus.square.on.square") {
                            beginDevelopVersionNameAction(.duplicate(activeVersion.id))
                        }
                        Button("Rename…", systemImage: "pencil") {
                            beginDevelopVersionNameAction(.rename(activeVersion.id))
                        }
                        Button(
                            developVersionCatalog?.defaultVersionID == activeVersion.id
                                ? "Clear Default" : "Set as Default",
                            systemImage: developVersionCatalog?.defaultVersionID == activeVersion.id
                                ? "star.slash" : "star"
                        ) {
                            toggleDefaultDevelopVersion(activeVersion.id)
                        }
                        Button("Promote to Primary…", systemImage: "arrow.up.doc") {
                            developVersionPendingPromotionID = activeVersion.id
                        }
                        Divider()
                        Button("Delete…", systemImage: "trash", role: .destructive) {
                            developVersionPendingDeleteID = activeVersion.id
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(activeDevelopVersionLabel)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.borderlessButton)
                .disabled(
                    developVersionCatalog == nil
                        || developVersionPersistenceState == .loading
                        || developVersionPersistenceState == .saving
                )

                Menu {
                    if developVersionCatalog?.activeVersionID != nil {
                        Button {
                            beginDevelopVersionComparison(with: .primary)
                        } label: {
                            Label(
                                "Primary (XMP)",
                                systemImage: developVersionComparisonTarget == .primary
                                    ? "checkmark" : "photo"
                            )
                        }
                    }

                    if let catalog = developVersionCatalog {
                        ForEach(catalog.versions.filter { $0.id != catalog.activeVersionID }) { version in
                            Button {
                                beginDevelopVersionComparison(with: .named(version.id))
                            } label: {
                                Label(
                                    version.name,
                                    systemImage: developVersionComparisonTarget == .named(version.id)
                                        ? "checkmark" : "camera.filters"
                                )
                            }
                        }
                    }

                    if isDevelopComparisonActive {
                        Divider()
                        Button("Close Comparison") { closeDevelopComparison() }
                    }
                } label: {
                    Text("Compare Version…")
                        .font(.caption)
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!hasDevelopVersionComparisonTargets || isDevelopVersionTransitioning)
                .help("Compare the current Develop version with Primary or another named version")

                Image(systemName: developVersionPersistenceState.systemImage)
                    .foregroundStyle(developVersionStatusColor)
                    .help(developVersionPersistenceState.label)
                    .accessibilityLabel("Version status: \(developVersionPersistenceState.label)")
            }

            if let activeVersion = activeNamedDevelopVersion {
                HStack(spacing: 5) {
                    Text(activeVersion.summary)
                    Text("•")
                    Text(developVersionPersistenceState.label)
                    if developVersionCatalog?.defaultVersionID == activeVersion.id {
                        Text("• Default")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(
                    "Created \(activeVersion.createdAt.formatted(date: .abbreviated, time: .shortened)); "
                        + "updated \(activeVersion.updatedAt.formatted(date: .abbreviated, time: .shortened))"
                )
                Text(
                    "Created \(activeVersion.createdAt.formatted(date: .abbreviated, time: .omitted))"
                        + " • Updated \(activeVersion.updatedAt.formatted(date: .abbreviated, time: .shortened))"
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

                if let warning = developVersionDependencyWarning(
                    for: activeVersion,
                    watermarkData: watermarkData
                ) {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Version dependency warning: \(warning)")
                }
            } else {
                Text("XMP-backed primary Develop state")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let warning = developVersionStorage?.portabilityWarning {
                Label(warning, systemImage: "externaldrive.badge.exclamationmark")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if let developVersionNotice {
                Label(developVersionNotice, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Develop version selector")
    }

    private func developVersionDiagnostics(
        for version: DevelopNamedVersion,
        watermarkData: [UUID: Data]
    ) -> [DevelopVersionDependencyDiagnostic] {
        version.snapshot.dependencyDiagnostics { watermarkData[$0] }
    }

    private func developVersionMenuLabel(
        for version: DevelopNamedVersion,
        isDefault: Bool,
        watermarkData: [UUID: Data]
    ) -> String {
        let suffix: String
        let diagnostics = developVersionDiagnostics(for: version, watermarkData: watermarkData)
        if diagnostics.contains(where: { $0.status == .missing }) {
            suffix = " • Missing Watermark"
        } else if diagnostics.contains(where: { $0.status == .changed }) {
            suffix = " • Changed Watermark"
        } else if diagnostics.contains(where: { $0.status == .unsupported }) {
            suffix = " • Unsupported Dependency"
        } else {
            suffix = ""
        }
        return version.name + (isDefault ? " (Default)" : "") + suffix
    }

    private func developVersionMenuIcon(
        for version: DevelopNamedVersion,
        isActive: Bool,
        watermarkData: [UUID: Data]
    ) -> String {
        let diagnostics = developVersionDiagnostics(for: version, watermarkData: watermarkData)
        return diagnostics.contains(where: { $0.status != .resolved })
            ? "exclamationmark.triangle.fill"
            : (isActive ? "checkmark" : "camera.filters")
    }

    private func developVersionDependencyWarning(
        for version: DevelopNamedVersion,
        watermarkData: [UUID: Data]
    ) -> String? {
        let diagnostics = developVersionDiagnostics(for: version, watermarkData: watermarkData)
        let missing = diagnostics.filter { $0.status == .missing }.count
        let changed = diagnostics.filter { $0.status == .changed }.count
        let unsupported = diagnostics.filter { $0.status == .unsupported }.count
        var parts: [String] = []
        if missing > 0 {
            parts.append("\(missing) watermark\(missing == 1 ? " is" : "s are") missing")
        }
        if changed > 0 {
            parts.append("\(changed) watermark\(changed == 1 ? " has" : "s have") changed")
        }
        if unsupported > 0 {
            parts.append("\(unsupported) dependenc\(unsupported == 1 ? "y is" : "ies are") unsupported")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "; ") + ". Rendering may not match the saved version."
    }

    private var cropInspectorControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Crop", systemImage: "crop")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Done") {
                    toggleCropControls()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: [])
                .help("Finish Crop (Return or C)")
            }

            Text("Drag the frame or its handles on the image. Hold Command for a free crop.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack {
                Text("Aspect Ratio")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                cropAspectRatioPicker
                    .frame(width: 120)
                    .onChange(of: cropAspectRatio) { _, newRatio in
                        // Both crop pickers share this selection. Observe it only on the
                        // always-present inspector so one change creates one undo step.
                        applyAspectRatioToCrop(newRatio)
                    }
            }

            cropRotationSliderRow

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Preview Zoom")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if abs(cropZoomScale - 1.0) > 0.01 {
                        Button {
                            resetCropZoom()
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Reset preview zoom to 100%")
                    }
                    Spacer()
                    Text("\(Int((cropZoomScale * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                EditSlider(
                    value: cropZoomBinding,
                    range: 0.25...3.0,
                    step: 0.01
                )
                .frame(height: 20)
                .onTapGesture(count: 2) {
                    resetCropZoom()
                }
                .onChange(of: cropZoomScale) { _, _ in
                    lastCropZoomScale = cropZoomScale
                }
            }

            Divider()

            Button(role: .destructive) {
                resetCrop()
            } label: {
                Label("Reset Crop", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!isCropEnabled)
            .help("Clear the crop and return to the full image")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cropPreviewToolbar: some View {
        HStack(spacing: 10) {
            Label("Crop", systemImage: "crop")
                .font(.system(size: 11, weight: .semibold))

            Divider()
                .frame(height: 22)

            cropAspectRatioPicker
                .frame(width: 108)

            Image(systemName: "rotate.left")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            EditSlider(
                value: cropAngleBinding,
                range: -45...45,
                step: 0.01,
                onEditingChanged: { editing in
                    isDraggingEditSlider = editing
                    if !editing {
                        commitEditAdjustments()
                    }
                },
                onDragValueChanged: { value in
                    updateCropAngleDragPreview(value)
                },
                onReset: {
                    resetCropAngle()
                    commitEditAdjustments()
                }
            )
            .frame(width: 130, height: 20)
            .help("Straighten angle. Hold Option for precision; double-click to reset.")

            Text(signedDoubleString(displayCropAngle, precision: 1) + "°")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 43, alignment: .trailing)

            Divider()
                .frame(height: 22)

            Button {
                resetCrop()
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!isCropEnabled)

            Button("Done") {
                toggleCropControls()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("Finish Crop (Return or C)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
    }

    private var cropAspectRatioPicker: some View {
        Picker("Aspect Ratio", selection: Binding(
            get: { cropAspectRatio },
            set: { cropAspectRatio = $0 }
        )) {
            ForEach(CropAspectRatio.menuOrder) { ratio in
                Text(ratio.label).tag(ratio)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .help("Crop aspect ratio")
        .accessibilityLabel("Crop Aspect Ratio")
    }

    private var cropRotationSliderRow: some View {
        sliderRow(
            "Straighten",
            value: cropAngleBinding,
            range: -45...45,
            step: 0.01,
            formatter: { signedDoubleString($0, precision: 2) + "°" },
            settingsMutator: { [self] _, value in
                updateCropAngleDragPreview(value)
            },
            onReset: {
                resetCropAngle()
            }
        )
    }

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: 8) {
                    ForEach(browserViewModel.visibleImages) { image in
                        EditFilmstripItemView(
                            image: image,
                            thumbnailService: browserViewModel.thumbnailService,
                            isSelected: browserViewModel.selectedImageIDs.contains(image.url)
                        )
                        .id(image.url)
                        .onTapGesture {
                            let modifiers = NSEvent.modifierFlags
                            requestDevelopImageSelection(image.url, modifiers: modifiers)
                        }
                        .onContinuousHover { phase in
                            switch phase {
                            case .active:
                                hoveredFilmstripURL = image.url
                            case .ended:
                                if hoveredFilmstripURL == image.url {
                                    hoveredFilmstripURL = nil
                                }
                            }
                        }
                        .contextMenu {
                            Button("Copy Settings", systemImage: "doc.on.doc") {
                                copyFilmstripSettings(from: image)
                            }

                            Button("Paste Settings", systemImage: "doc.on.clipboard") {
                                pasteCopiedSettings(to: [image.url])
                            }
                            .disabled(browserViewModel.copiedCameraRawSettings == nil)

                            if image.url != selectedImageURL {
                                Divider()
                                Button("Compare with Current Image", systemImage: "rectangle.split.2x1") {
                                    openDevelopComparison(with: image)
                                }

                                Button("Copy Settings to Current Selection", systemImage: "paintbrush") {
                                    applyFilmstripSettingsFromImageToCurrentSelection(image)
                                }
                                .disabled(browserViewModel.selectedImageIDs.isEmpty)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: filmstripKeyboardScrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeInOut(duration: 0.16)) {
                    // No anchor means SwiftUI moves only as far as necessary to reveal the item.
                    proxy.scrollTo(target)
                }
            }
            .onAppear {
                // Defer until the lazy stack has completed its first layout. Otherwise a
                // selection far into the folder can be highlighted while remaining outside
                // the filmstrip's initial visible range.
                DispatchQueue.main.async {
                    guard let target = selectedImageURL else { return }
                    proxy.scrollTo(target, anchor: .center)
                }
            }
        }
        .frame(height: 120)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func handleDevelopVersionImageChange(from oldURL: URL?, to newURL: URL?) {
        guard oldURL != newURL else { return }
        resetDevelopVersionState()
        loadDevelopVersionCatalog()
    }

    private func resetDevelopVersionState() {
        developVersionSession.reset()
        developVersionNameAction = nil
        developVersionNameDraft = ""
        developVersionPendingDeleteID = nil
        developVersionPendingPromotionID = nil
    }

    private func loadDevelopVersionCatalog() {
        guard let image = selectedImage else {
            resetDevelopVersionState()
            return
        }

        developVersionSession.beginLoading(
            imageURL: image.url,
            orientation: image.exifOrientation
        ) {
            installLoadedDevelopVersionIfReady()
        }
    }

    /// Installs the persisted active named version only after the XMP-backed Primary buffer for
    /// this image has finished loading. That Primary snapshot remains in memory for lossless
    /// switching back without adding it to the JSON catalog.
    private func installLoadedDevelopVersionIfReady() {
        guard let installation = developVersionSession.loadedSettingsToInstallIfReady(
            metadataIsLoading: metadataViewModel.isLoading,
            selectedCount: metadataViewModel.selectedCount,
            metadataSelectedURL: metadataViewModel.selectedURLs.first,
            currentPrimarySettings: metadataViewModel.editingMetadata.cameraRaw
        ) else { return }
        installDevelopSettings(installation.settings)
    }

    private func installDevelopSettings(_ settings: CameraRawSettings?) {
        metadataViewModel.editingMetadata.cameraRaw = settings
        // Named-version changes belong to the JSON catalog, not the XMP-backed Primary record.
        metadataViewModel.hasChanges = false
        editUndoManager.removeAllActions()
        selectedLayer = .global
        maskInteraction.stopBrushPainting()
        resetCropZoom()
        syncCameraRawToImageFile()
        renderPreview()
        syncViewportToMetal()
        updateCleanFeedMirror(enabled: cleanFeedController.isEnabled)
    }

    private func beginDevelopVersionNameAction(_ action: DevelopVersionNameAction) {
        developVersionNameAction = action
        switch action {
        case .create:
            let nextNumber = (developVersionCatalog?.versions.count ?? 0) + 1
            developVersionNameDraft = "Version \(nextNumber)"
        case let .rename(id):
            developVersionNameDraft = developVersionCatalog?.versions
                .first(where: { $0.id == id })?.name ?? ""
        case let .duplicate(id):
            let sourceName = developVersionCatalog?.versions
                .first(where: { $0.id == id })?.name ?? "Version"
            developVersionNameDraft = "\(sourceName) Copy"
        }
    }

    private func performDevelopVersionNameAction() {
        guard let action = developVersionNameAction else { return }
        let name = developVersionNameDraft
        developVersionNameAction = nil
        developVersionNameDraft = ""
        closeDevelopComparison()

        switch action {
        case .create:
            createDevelopVersion(name: name)
        case let .rename(id):
            renameDevelopVersion(id: id, name: name)
        case let .duplicate(id):
            duplicateDevelopVersion(id: id, name: name)
        }
    }

    private func createDevelopVersion(name: String) {
        guard var candidate = developVersionCatalog else { return }
        let settings = metadataViewModel.editingMetadata.cameraRaw ?? CameraRawSettings()
        if candidate.activeVersionID == nil {
            primaryDevelopSettings = metadataViewModel.editingMetadata.cameraRaw
        }

        do {
            _ = try candidate.createVersion(
                name: name,
                settings: settings,
                watermarkDataProvider: watermarkStore.imageData(forAssetID:)
            )
        } catch {
            developVersionNotice = error.localizedDescription
            return
        }
        persistDevelopVersionCatalog(candidate)
    }

    private func duplicateDevelopVersion(id: UUID, name: String) {
        guard var candidate = developVersionCatalog else { return }
        do {
            _ = try candidate.duplicateVersion(id: id, name: name)
        } catch {
            developVersionNotice = error.localizedDescription
            return
        }
        persistDevelopVersionCatalog(candidate)
    }

    private func renameDevelopVersion(id: UUID, name: String) {
        guard var candidate = developVersionCatalog else { return }
        do {
            try candidate.renameVersion(id: id, name: name)
        } catch {
            developVersionNotice = error.localizedDescription
            return
        }
        persistDevelopVersionCatalog(candidate)
    }

    private func toggleDefaultDevelopVersion(_ id: UUID) {
        guard var candidate = developVersionCatalog else { return }
        do {
            try candidate.setDefaultVersion(candidate.defaultVersionID == id ? nil : id)
        } catch {
            developVersionNotice = error.localizedDescription
            return
        }
        persistDevelopVersionCatalog(candidate)
    }

    private func deleteDevelopVersion(id: UUID) {
        developVersionPendingDeleteID = nil
        closeDevelopComparison()
        guard var candidate = developVersionCatalog else { return }
        let wasActive = candidate.activeVersionID == id
        guard candidate.deleteVersion(id: id) else { return }
        persistDevelopVersionCatalog(
            candidate,
            settingsToInstall: wasActive ? primaryDevelopSettings : nil,
            installsSettings: wasActive
        )
    }

    private var developVersionPromotionMessage: String {
        guard let id = developVersionPendingPromotionID,
              let version = developVersionCatalog?.versions.first(where: { $0.id == id }),
              let imageURL = selectedImageURL else { return "" }

        let primarySummary = primaryDevelopSettings?.hasEffectiveEdits == true
            ? "Develop adjustments"
            : "No adjustments"
        let sidecarPath = XMPSidecarService().sidecarURL(for: imageURL).path
        let availableWatermarkIDs = Set(watermarkStore.allAssets().map(\.id))
        let diagnostics = version.snapshot.dependencyDiagnostics { id in
            guard availableWatermarkIDs.contains(id) else { return nil }
            return watermarkStore.imageData(forAssetID: id)
        }
        let unresolved = diagnostics.filter { $0.status != .resolved }.count
        let dependencyWarning = unresolved == 0
            ? ""
            : " Warning: \(unresolved) external dependency \(unresolved == 1 ? "is" : "are") missing or changed."

        return "\(version.name) (\(version.summary)) will replace Primary (\(primarySummary)) at \(sidecarPath). A dated named recovery version of the current Primary will be saved first, and the XMP write must pass read-back verification.\(dependencyWarning)"
    }

    private func promoteDevelopVersion(id: UUID) {
        developVersionPendingPromotionID = nil
        guard !developVersionSession.hasTransition,
              let repository = developVersionSession.repository as? DevelopVersionCatalogRepository,
              let imageURL = selectedImageURL,
              var candidate = developVersionCatalog else { return }
        closeDevelopComparison()
        developVersionSession.cancelSave()

        let versionName = candidate.versions.first(where: { $0.id == id })?.name ?? "Named version"
        let recoveryName = "Primary before promotion — \(Date().formatted(date: .abbreviated, time: .shortened))"
        let preparation: DevelopVersionPromotionPreparation
        do {
            preparation = try candidate.preparePromotion(
                of: id,
                currentSettings: metadataViewModel.editingMetadata.cameraRaw ?? CameraRawSettings(),
                primarySettings: primaryDevelopSettings,
                recoveryName: recoveryName,
                watermarkDataProvider: watermarkStore.imageData(forAssetID:)
            )
        } catch {
            developVersionPersistenceState = .failed(error.localizedDescription)
            developVersionNotice = error.localizedDescription
            return
        }

        let service = DevelopVersionPromotionService(
            repository: repository,
            imageURL: imageURL,
            orientation: selectedImageOrientation
        )
        let sourceHash = preparation.catalog.source.sha256
        developVersionPersistenceState = .saving
        developVersionNotice = nil
        developVersionSession.startTransition {
            do {
                let result = try await service.promote(preparation)
                guard !Task.isCancelled,
                      developVersionRevision?.sha256 == sourceHash,
                      selectedImageURL == imageURL else { return }
                developVersionCatalog = result.catalog
                developVersionStorage = result.storage
                primaryDevelopSettings = result.promotedSettings
                developVersionPersistenceState = .saved
                installDevelopSettings(result.promotedSettings)
                metadataViewModel.hasChanges = false
                showCopyPasteFeedback("Promoted \(versionName) to Primary and verified XMP")
            } catch is CancellationError {
                return
            } catch {
                guard developVersionRevision?.sha256 == sourceHash,
                      selectedImageURL == imageURL else { return }
                if let promotionError = error as? DevelopVersionPromotionError,
                   promotionError.recoveryCatalogWasSaved {
                    // The first catalog write is durable. Reflect that recovery snapshot locally
                    // even when a later XMP/read-back/finalization boundary fails.
                    developVersionCatalog = preparation.catalog
                    let actualPrimary = XMPSidecarService().loadSidecar(for: imageURL)?.cameraRaw
                    primaryDevelopSettings = actualPrimary
                }
                developVersionPersistenceState = .failed(error.localizedDescription)
                developVersionNotice = error.localizedDescription
            }
        }
    }

    private func switchDevelopVersion(to targetID: UUID?) {
        guard targetID != developVersionCatalog?.activeVersionID,
              var candidate = developVersionCatalog else { return }
        closeDevelopComparison()

        developVersionSession.cancelSave()
        let currentSettings = metadataViewModel.editingMetadata.cameraRaw
        let targetSettings: CameraRawSettings?
        do {
            targetSettings = try candidate.prepareSwitch(
                to: targetID,
                savingCurrentSettings: currentSettings,
                primarySettings: primaryDevelopSettings,
                watermarkDataProvider: watermarkStore.imageData(forAssetID:)
            )
        } catch {
            developVersionNotice = error.localizedDescription
            return
        }

        // Persist both the flushed source version and the new active selection before changing
        // the editor. A write failure leaves the visible version untouched.
        persistDevelopVersionCatalog(
            candidate,
            settingsToInstall: targetSettings,
            installsSettings: true
        )
    }

    private func persistDevelopVersionCatalog(
        _ candidate: DevelopVersionCatalog,
        settingsToInstall: CameraRawSettings? = nil,
        installsSettings: Bool = false
    ) {
        developVersionSession.persist(candidate) {
            if installsSettings {
                installDevelopSettings(settingsToInstall)
            } else {
                metadataViewModel.hasChanges = false
            }
        }
    }

    private func scheduleActiveDevelopVersionSave() {
        let didSchedule = developVersionSession.scheduleActiveSave(
            settings: metadataViewModel.editingMetadata.cameraRaw ?? CameraRawSettings(),
            watermarkDataProvider: watermarkStore.imageData(forAssetID:)
        ) {
            metadataViewModel.hasChanges = false
        }
        if didSchedule {
            metadataViewModel.hasChanges = false
        }
    }

    private func flushActiveDevelopVersion(
        reason: DevelopVersionFlushReason
    ) async -> DevelopVersionFlushOutcome {
        await developVersionSession.flushActive(
            reason: reason,
            settings: metadataViewModel.editingMetadata.cameraRaw ?? CameraRawSettings(),
            watermarkDataProvider: watermarkStore.imageData(forAssetID:)
        ) {
            metadataViewModel.hasChanges = false
        }
    }

    private func requestDevelopImageSelection(
        _ imageURL: URL,
        modifiers: NSEvent.ModifierFlags = []
    ) {
        guard !developVersionSession.hasTransition else { return }
        let oldSelectedIDs = browserViewModel.selectedImageIDs
        let oldAnchor = browserViewModel.lastClickedImageURL
        let visibleImages = browserViewModel.visibleImages
        let visibleIndex = browserViewModel.urlToVisibleIndex

        developVersionSession.startTransition {
            let outcome = await flushActiveDevelopVersion(reason: .imageNavigation)
            guard !Task.isCancelled else { return }
            guard outcome == .succeeded else {
                // Explicitly retain both pieces of selection state. This also protects against
                // future callers that optimistically mutate selection before requesting a flush.
                browserViewModel.selectedImageIDs = oldSelectedIDs
                browserViewModel.lastClickedImageURL = oldAnchor
                return
            }

            if modifiers.contains(.command) {
                if browserViewModel.selectedImageIDs.contains(imageURL) {
                    browserViewModel.selectedImageIDs.remove(imageURL)
                } else {
                    browserViewModel.selectedImageIDs.insert(imageURL)
                }
            } else if modifiers.contains(.shift), let anchor = oldAnchor,
                      let anchorIndex = visibleIndex[anchor],
                      let imageIndex = visibleIndex[imageURL] {
                let range = min(anchorIndex, imageIndex)...max(anchorIndex, imageIndex)
                for index in range {
                    browserViewModel.selectedImageIDs.insert(visibleImages[index].url)
                }
            } else {
                browserViewModel.selectedImageIDs = [imageURL]
            }
            browserViewModel.lastClickedImageURL = imageURL
            filmstripKeyboardScrollTarget = imageURL
            isWorkspaceFocused = true
        }
    }

    private func requestAdjacentDevelopImage(forward: Bool) {
        guard let currentURL = selectedImageURL,
              let currentIndex = browserViewModel.urlToVisibleIndex[currentURL] else { return }
        let targetIndex = forward ? currentIndex + 1 : currentIndex - 1
        guard browserViewModel.visibleImages.indices.contains(targetIndex) else { return }
        requestDevelopImageSelection(browserViewModel.visibleImages[targetIndex].url)
    }

    private func requestEditWorkspaceExit() {
        guard !developVersionSession.hasTransition else { return }
        developVersionSession.startTransition {
            let outcome = await flushActiveDevelopVersion(reason: .workspaceExit)
            guard !Task.isCancelled else { return }
            if outcome == .succeeded {
                onExit()
            }
        }
    }

    private func handleEditWorkspaceDisappear() {
        cancelColorLUTImport()
        importingLUTForLayerID = nil
        isSpaceHandToolActive = false
        transientPreview.endImageSession()
        cropSession.endImageSession()
        maskInteraction.endImageSession()
        metalPipeline?.maskMattePreviewMaskID = nil
        developComparison.close()
        NSCursor.arrow.set()

        // Primary has already followed the XMP commit path during editing. A named version reaches
        // here only after the coordinated JSON flush succeeds; sync its in-memory browser preview
        // without scheduling a second delayed write while the view is being destroyed.
        if developVersionCatalog?.activeVersionID == nil {
            commitEditAdjustments()
        } else {
            syncCameraRawToImageFile()
        }

        if let registrationID = developVersionFlushRegistrationID {
            DevelopVersionFlushCoordinator.shared.unregister(registrationID)
            developVersionFlushRegistrationID = nil
        }
        developVersionSession.reset()
        aiMaskSelection.endImageSession()
        previewSession.endImageSession()
        previewRender.endImageSession()

        // Tear down the clean-feed mirror; browse mode resumes driving the feed.
        metalPipeline?.mirror = nil
        metalPipeline?.onParamsChanged = nil
        cleanFeedController.editModeActive = false
        cleanFeedController.useEditPipeline = false
        cleanFeedController.feedPipeline?.clearSourceTexture()
        cleanFeedController.requestFeedRedraw()

        metadataViewModel.isInEditView = false
        metalPipeline?.updateOverlayParams(geometry: nil, visible: false)
        metalCoordinator.stopContinuousRendering()
        scopeViewModel.metalScopeCoordinator?.stopContinuousRendering()
        scopeViewModel.clearMetal()
        scopeThrottleTask?.cancel()
        scopeThrottleTask = nil
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
        if let monitor = middleMouseEventMonitor {
            NSEvent.removeMonitor(monitor)
            middleMouseEventMonitor = nil
        }
        hoveredFilmstripURL = nil

        // Proactively re-warm caches for every image whose develop settings changed this session,
        // so the return to the grid/loupe is instant and correct instead of catching up reactively
        // a beat later (which flashes a stale preview). `commitEditAdjustments` above already flushed
        // the current image's edit through `syncCameraRawToImageFile`, so it's in the set too.
        let editedURLs = editedURLsThisSession
        guard !editedURLs.isEmpty else { return }

        // Snapshot settings + orientation off the MainActor model into plain values so the warm
        // tasks don't reach back into `browserViewModel.images`. `thumbSettings` keeps the raw
        // settings (thumbnails render SDR); `fsSettings` applies the loupe's HDR normalization so
        // warmed full-screen previews aren't SDR-clipped relative to the foreground render.
        var thumbSettings: [URL: CameraRawSettings] = [:]
        var fsSettings: [URL: CameraRawSettings] = [:]
        var orientationByURL: [URL: Int] = [:]
        let thumbnailService = browserViewModel.thumbnailService
        for url in editedURLs {
            guard let index = browserViewModel.urlToImageIndex[url] else { continue }
            let imageFile = browserViewModel.images[index]
            orientationByURL[url] = imageFile.exifOrientation
            guard let settings = imageFile.cameraRawSettings, !settings.isEmpty else { continue }
            thumbSettings[url] = settings
            var normalized = settings
            if imageFile.isNativeHDR, normalized.hdrEditMode == nil {
                normalized.hdrEditMode = 1
            }
            fsSettings[url] = normalized
        }

        // Regenerate grid thumbnails so the browser reflects the edits immediately.
        for (url, settings) in thumbSettings {
            let orientation = orientationByURL[url] ?? 1
            thumbnailService.invalidateEditedThumbnail(for: url)
            Task.detached(priority: .utility) {
                _ = await thumbnailService.renderEditedThumbnail(
                    for: url,
                    settings: settings,
                    exifOrientation: orientation
                )
            }
        }

        // Pre-warm the full-screen edited previews (loupe + grid full-screen cache). Screen-res
        // decode matches the loupe's own load path.
        let screenScale = NSScreen.main?.backingScaleFactor ?? 2.0
        let screenMaxPx = max(NSScreen.main?.frame.width ?? 3840, NSScreen.main?.frame.height ?? 2160) * screenScale
        let fsSettingsSnapshot = fsSettings
        let orientationSnapshot = orientationByURL
        browserViewModel.fullScreenImageCache.warmEditedPreviews(
            for: Array(fsSettingsSnapshot.keys),
            screenMaxPx: screenMaxPx,
            settingsForURL: { fsSettingsSnapshot[$0] },
            orientationForURL: { orientationSnapshot[$0] ?? 1 }
        )
    }

    private func handleEditWorkspaceAppear() {
        ensureSingleSelection()
        if metalPipeline == nil {
            let device = MetalPreviewView.Coordinator.device
            let queue = MetalPreviewView.Coordinator.commandQueue
            metalPipeline = MetalLivePreviewPipeline(device: device, commandQueue: queue)
            if let pipeline = metalPipeline {
                Task.detached(priority: .low) {
                    pipeline.warmupCIContext()
                }
            }
        }
        if let pipeline = metalPipeline {
            scopeViewModel.metalEditPipeline = pipeline
            if scopeViewModel.metalScopePipeline == nil {
                let device = MetalPreviewView.Coordinator.device
                let queue = MetalPreviewView.Coordinator.commandQueue
                if let scopePipeline = MetalScopePipeline(device: device, commandQueue: queue) {
                    scopeViewModel.metalScopePipeline = scopePipeline
                    scopeViewModel.metalScopeCoordinator = MetalScopeView.Coordinator(scopePipeline: scopePipeline)
                }
            }
        }
        cleanFeedController.editModeActive = true
        // Wire the clean-feed mirror only when the feed is actually enabled, so users
        // who never use it pay no overhead on the core edit path.
        updateCleanFeedMirror(enabled: cleanFeedController.isEnabled)

        updateGamutClipMode()
        metadataViewModel.isInEditView = true
        developVersionFlushRegistrationID = DevelopVersionFlushCoordinator.shared.register {
            reason in
            await flushActiveDevelopVersion(reason: reason)
        }
        loadDevelopVersionCatalog()
        editLog.info("[\(selectedImageURL?.lastPathComponent ?? "nil")] loadSelectedImagePreview triggered by: onAppear")
        loadSelectedImagePreview()
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [self] event in
            handleKeyEvent(event)
        }
        // DaVinci Resolve-style grade copy: middle-click the hovered filmstrip thumbnail to
        // apply its develop settings to the current selection without changing that selection.
        middleMouseEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [self] event in
            guard event.buttonNumber == 2,
                  let sourceURL = hoveredFilmstripURL,
                  let source = browserViewModel.images.first(where: { $0.url == sourceURL }) else {
                return event
            }
            applyFilmstripSettingsFromImageToCurrentSelection(source)
            return nil
        }
    }

    private func ensureSingleSelection() {
        if browserViewModel.selectedImageIDs.count == 1 { return }
        guard let fallback = browserViewModel.lastClickedImageURL ?? browserViewModel.visibleImages.first?.url else { return }
        browserViewModel.selectedImageIDs = [fallback]
        browserViewModel.lastClickedImageURL = fallback
    }

    private func ensureAtLeastOneSelected() {
        if !browserViewModel.selectedImageIDs.isEmpty { return }
        guard let fallback = browserViewModel.lastClickedImageURL ?? browserViewModel.visibleImages.first?.url else { return }
        browserViewModel.selectedImageIDs = [fallback]
        browserViewModel.lastClickedImageURL = fallback
    }

    /// Auto-enable HDR mode when no explicit `hdrEditMode` has been set in metadata.
    ///
    /// Priority order:
    /// 1. **XMP / embedded metadata** — if `hdrEditMode` was read from the file, it is
    ///    authoritative and this method is a no-op (`hdrEditMode != nil`).
    /// 2. **Native HDR** (PQ/HLG transfer function) — always auto-enables, even before
    ///    the async metadata load finishes, because the file's transfer function is
    ///    inherent to the image data.
    /// 3. **"Render RAW as HDR" preference** — only applied when `includeRawPreference`
    ///    is `true`, which should be after the metadata load has completed so that any
    ///    XMP `hdrEditMode` value takes precedence.
    ///
    /// - Parameter includeRawPreference: Pass `true` only after the metadata load has
    ///   finished (i.e. in the `metadataLoadGeneration` handler), so that XMP values
    ///   are already present and won't be overridden by the preference.
    private func autoEnableHDRIfNeeded(includeRawPreference: Bool = false) {
        guard let image = selectedImage, image.isNativeHDR,
              metadataViewModel.editingMetadata.cameraRaw?.hdrEditMode == nil else { return }

        // For RAW files, isNativeHDR may reflect the user's "Render RAW as HDR"
        // preference rather than the file's actual transfer function. Skip the
        // preference-based case when metadata hasn't loaded yet, so that XMP
        // values get a chance to take priority.
        if !includeRawPreference && SupportedImageFormats.isRaw(url: image.url) {
            return
        }
        let url = image.url
        editLog.info("[\(url.lastPathComponent)] Auto-enabling HDR mode for native HDR image")
        if metadataViewModel.editingMetadata.cameraRaw == nil {
            metadataViewModel.editingMetadata.cameraRaw = CameraRawSettings()
        }
        metadataViewModel.editingMetadata.cameraRaw?.hdrEditMode = 1
        // Propagate to ImageFile
        if let index = browserViewModel.urlToImageIndex[url] {
            if browserViewModel.images[index].cameraRawSettings == nil {
                browserViewModel.images[index].cameraRawSettings = CameraRawSettings()
            }
            browserViewModel.images[index].cameraRawSettings?.hdrEditMode = 1
        }
    }

    private func loadSelectedImagePreview() {
        let filename = selectedImageURL?.lastPathComponent ?? "nil"
        editLog.info("[\(filename)] loadSelectedImagePreview: resetting state, cancelling previous tasks")
        transientPreview.beginImageSession(selectedImageURL)
        previewSession.beginImageSession(
            selectedImageURL,
            orientation: selectedImageURL == nil ? nil : selectedImageOrientation
        )
        previewRender.beginImageSession()
        sourceImage = nil
        sourceCIImage = nil
        asShotWhiteBalance = nil
        isPickingWhiteBalance = false
        aiMaskSelection.beginImageSession(selectedImageURL)
        maskInteraction.beginImageSession(selectedImageURL)
        wbPickDragRect = nil
        metalPipeline?.maskMattePreviewMaskID = nil
        metalPipeline?.asShotTemperature = 6500
        metalPipeline?.asShotTint = 0
        previewCIImage = nil
        metalPipeline?.clearSourceTexture()
        metalPipeline?.updateOverlayParams(geometry: nil, visible: false)
        cropSession.beginImageSession(selectedImageURL, isCropEnabled: isCropEnabled)
        resetEditZoom()
        selectedLayer = .global

        guard let selectedImageURL else {
            editLog.info("[nil] loadSelectedImagePreview: no selectedImageURL, returning")
            return
        }

        autoEnableHDRIfNeeded()

        let previewMaxPixelSize = previewWorkingMaxPixelSize
        isLoadingPreview = true
        let isRaw = SupportedImageFormats.isRaw(url: selectedImageURL)

        // The file's baked-in orientation can differ from the in-memory orientation:
        // C2PA images can't be modified, and rotation writes the new tag to the file
        // asynchronously. Each decode below computes its own corrective rotation from
        // the orientation of the bytes it actually decoded — a single upfront read can
        // race the pending write (Phase 2 decodes seconds later) and over-rotate.
        let targetOrientation = selectedImageOrientation
        // The preview-session owner recorded this image/orientation before reset so a later
        // in-app rotation can rotate the retained source in place instead of re-decoding.

        editLog.info("[\(filename)] loadSelectedImagePreview: starting previewTask (isRaw=\(isRaw), maxPx=\(Int(previewMaxPixelSize)), targetOrientation=\(targetOrientation))")

        previewTask = Task {
            guard !Task.isCancelled else {
                editLog.info("[\(filename)] previewTask: cancelled before start")
                return
            }

            if isRaw {
                // RAW two-phase load: embedded JPEG preview (instant), then a
                // CIRAWFilter decode at screen resolution (not full sensor — that
                // wasted seconds demosaicing 45MP for a ~5MP display). Full-res is
                // loaded lazily on zoom via loadFullResEditTextureIfNeeded().

                // Phase 1: Extract embedded JPEG preview from RAW container (no RAW decode).
                // Oriented to the in-memory target inside the task — see orientedToTarget.
                let phase1Start = ContinuousClock.now
                let quickPreview = await Task.detached(priority: .userInitiated) { () -> (image: NSImage?, ciImage: CIImage?)? in
                    guard let result = await FullScreenImageCache.extractEmbeddedPreviewOffPoolWithOrientation(
                        from: selectedImageURL
                    ) else { return nil }
                    let nsImage = NSImage(
                        cgImage: result.image,
                        size: NSSize(width: result.image.width, height: result.image.height)
                    )
                    let oriented = Self.orientedToTarget(
                        ciImage: CIImage(cgImage: result.image), nsImage: nsImage,
                        from: result.orientation, to: targetOrientation
                    )
                    return (image: oriented.nsImage, ciImage: oriented.ciImage)
                }.value
                let phase1Elapsed = ContinuousClock.now - phase1Start

                guard !Task.isCancelled else {
                    editLog.info("[\(filename)] Phase 1: cancelled after \(phase1Elapsed)")
                    return
                }

                // Thumbnail fallback needs no correction either — thumbnails are
                // kept rotated to match the in-memory orientation.
                if let quickPreview, let image = quickPreview.image {
                    editLog.info("[\(filename)] Phase 1: embedded preview in \(phase1Elapsed) (\(image.size.width)x\(image.size.height))")
                    sourceImage = image
                    sourceCIImage = quickPreview.ciImage
                } else {
                    editLog.info("[\(filename)] Phase 1: no embedded preview, falling back to thumbnail")
                    let thumbnail = await browserViewModel.thumbnailService.loadThumbnail(for: selectedImageURL)
                    guard !Task.isCancelled else {
                        editLog.info("[\(filename)] Phase 1: cancelled during thumbnail fallback")
                        return
                    }
                    sourceImage = thumbnail
                    sourceCIImage = thumbnail?.tiffRepresentation.flatMap { CIImage(data: $0) }
                }

                // Sync viewport before Metal upload so the CIImage fallback path
                // (used while the texture upload is in flight) letterboxes correctly
                // instead of stretching the preview to fill the drawable.
                syncViewportToMetal()

                // Upload Phase 1 preview to Metal for immediate interactive editing
                // (mirrors non-RAW path so WB/tonal adjustments render as soon as
                // metadata loads, even before the full RAW decode completes).
                // sourceCIImage is already target-oriented — no correction here.
                if let ci = sourceCIImage, let pipeline = metalPipeline {
                    await Task.detached(priority: .medium) {
                        pipeline.uploadSourceImage(ci, exifOrientation: targetOrientation)
                    }.value
                    guard !Task.isCancelled else {
                        editLog.info("[\(filename)] Phase 1: cancelled during Metal upload")
                        return
                    }
                }
                syncViewportToMetal()
                renderPreview()
                isLoadingPreview = false
                isDecodingFullResolution = true

                // Phase 2: CIRAWFilter decode at screen resolution → Metal texture.
                // After upload, materialize sourceCIImage at screen resolution to release
                // the heavyweight CIRAWFilter pipeline (~260MB per instance).
                if let pipeline = metalPipeline {
                    let cachedWB = pipeline.applyCachedTexture(for: selectedImageURL, exifOrientation: targetOrientation)
                    let cacheHit = cachedWB != nil
                    if let cachedWB {
                        // Apply cached as-shot WB from the flat RAW pre-decode so the
                        // precached texture renders with correct white balance and tone.
                        asShotWhiteBalance = (temperature: cachedWB.neutralTemperature, tint: cachedWB.neutralTint)
                        pipeline.asShotTemperature = Double(cachedWB.neutralTemperature)
                        pipeline.asShotTint = Double(cachedWB.neutralTint)
                        syncViewportToMetal()
                        renderPreview()
                    }
                    editLog.info("[\(filename)] Phase 2: starting (cacheHit=\(cacheHit))")

                    let phase2Start = ContinuousClock.now
                    let rawResult: FullScreenImageCache.RAWDecodeResult? = await Task.detached(priority: .userInitiated) {
                        // Read the tag adjacent to the decode so the correction matches
                        // these bytes even if a pending rotation write lands mid-load.
                        let orientation = FullScreenImageCache.fileEXIFOrientation(at: selectedImageURL)
                        guard let result = FullScreenImageCache.loadRAWImage(
                            from: selectedImageURL,
                            draftMode: false,
                            maxPixelSize: previewMaxPixelSize
                        ) else { return nil }
                        let oriented = Self.orientedToTarget(
                            ciImage: result.image, nsImage: nil,
                            from: orientation, to: targetOrientation
                        ).ciImage ?? result.image
                        return FullScreenImageCache.RAWDecodeResult(
                            image: oriented,
                            neutralTemperature: result.neutralTemperature,
                            neutralTint: result.neutralTint
                        )
                    }.value
                    let rawCIImage = rawResult?.image
                    let decodeElapsed = ContinuousClock.now - phase2Start

                    if let rawResult {
                        asShotWhiteBalance = (temperature: rawResult.neutralTemperature, tint: rawResult.neutralTint)
                        // Propagate to Metal pipeline so WB adjustments are relative to as-shot
                        if let pipeline = metalPipeline {
                            pipeline.asShotTemperature = Double(rawResult.neutralTemperature)
                            pipeline.asShotTint = Double(rawResult.neutralTint)
                        }
                    }

                    guard !Task.isCancelled else {
                        editLog.info("[\(filename)] Phase 2: cancelled after decode (\(decodeElapsed))")
                        return
                    }
                    editLog.info("[\(filename)] Phase 2: decoded in \(decodeElapsed) (result=\(rawCIImage != nil))")

                    if let rawCIImage {
                        if cacheHit {
                            editLog.info("[\(filename)] Phase 2: upgrading cached texture to full resolution")
                        }
                        let uploadStart = ContinuousClock.now
                        // Already target-oriented from the decode task.
                        await Task.detached(priority: .medium) {
                            pipeline.uploadSourceImage(rawCIImage, exifOrientation: targetOrientation)
                        }.value
                        let uploadElapsed = ContinuousClock.now - uploadStart
                        guard !Task.isCancelled else {
                            editLog.info("[\(filename)] Phase 2: cancelled after upload (\(uploadElapsed))")
                            return
                        }
                        editLog.info("[\(filename)] Phase 2: texture uploaded in \(uploadElapsed)")
                        // Eagerly update Metal params before state changes — setting
                        // isDecodingFullResolution triggers SwiftUI re-eval → setNeedsDisplay,
                        // which would otherwise draw the new flat RAW texture with stale params.
                        syncViewportToMetal()
                        renderPreview()
                    }
                    isDecodingFullResolution = false

                    // Materialize sourceCIImage at screen resolution to release the heavy
                    // CIRAWFilter decode graph. The Metal texture holds full-res data for
                    // interactive editing; sourceCIImage is only used for scope/preview CGImage.
                    if let rawCIImage {
                        let materialized: CIImage? = await Task.detached(priority: .medium) {
                            let extent = rawCIImage.extent
                            let maxDim = max(extent.width, extent.height)
                            let targetPx = previewMaxPixelSize
                            let scale = maxDim > targetPx * 1.5 ? targetPx / maxDim : 1.0
                            let downsampled = scale < 1.0
                                ? rawCIImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                                : rawCIImage
                            guard let cgImage = CameraRawApproximation.ciContext.createCGImage(
                                downsampled, from: downsampled.extent,
                                format: .RGBAh,
                                colorSpace: CameraRawApproximation.workingColorSpace
                            ) else { return nil }
                            return CIImage(cgImage: cgImage)
                        }.value
                        sourceCIImage = materialized ?? rawCIImage
                    }
                    let totalPhase2 = ContinuousClock.now - phase2Start
                    editLog.info("[\(filename)] Phase 2: complete in \(totalPhase2), hasTexture=\(pipeline.hasSourceTexture)")
                    syncViewportToMetal()
                    renderPreview()

                    // Pre-cache adjacent RAW images at screen resolution for instant navigation.
                    precacheAdjacentRAWTextures(
                        currentURL: selectedImageURL,
                        pipeline: pipeline
                    )

                    // If the user already zoomed in while Phase 2 was decoding, upgrade
                    // the now-current screen-res texture to full resolution.
                    loadFullResEditTextureIfNeeded()
                }
            } else {
                // Non-RAW two-phase load (mirrors RAW strategy):
                // Phase 1: Quick preview at screen resolution for immediate display.
                // Phase 2: Full-resolution CIImage → Metal texture for sharp editing.

                // Phase 1: HDR-preserving path (keeps float values >1.0 for HEIC-HLG, AVIF, JXL).
                // Falls back to SDR CGImageSource path for formats CIImage can't decode.
                let phase1Start = ContinuousClock.now
                // Oriented to the in-memory target inside the task — see orientedToTarget.
                let previewSource = await Task.detached(priority: .userInitiated) { () -> (image: NSImage?, ciImage: CIImage?) in
                    if let result = await FullScreenImageCache.loadHDRPreviewOffPoolWithOrientation(from: selectedImageURL, maxPixelSize: previewMaxPixelSize) {
                        // Orient BEFORE rendering the NSImage so it comes out corrected for free.
                        let correction = ImageFile.orientationCorrection(from: result.orientation, to: targetOrientation)
                        let ci = correction != .up ? result.image.oriented(correction) : result.image
                        // Stamp content headroom so the Phase-1 NSImage preview engages EDR
                        // before the Metal texture is ready (otherwise the develop view briefly
                        // flips to SDR). See CameraRawApproximation.createDisplayCGImage.
                        if let cgImage = CameraRawApproximation.createDisplayCGImage(ci, from: ci.extent) {
                            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                            return (image: nsImage, ciImage: ci)
                        }
                    }
                    if let result = await FullScreenImageCache.loadDownsampledOffPoolWithOrientation(
                        from: selectedImageURL,
                        maxPixelSize: previewMaxPixelSize
                    ) {
                        let image = NSImage(
                            cgImage: result.image,
                            size: NSSize(width: result.image.width, height: result.image.height)
                        )
                        let oriented = Self.orientedToTarget(
                            ciImage: CIImage(cgImage: result.image), nsImage: image,
                            from: result.orientation, to: targetOrientation
                        )
                        return (image: oriented.nsImage, ciImage: oriented.ciImage)
                    }
                    if let image = NSImage(contentsOf: selectedImageURL) {
                        let orientation = FullScreenImageCache.fileEXIFOrientation(at: selectedImageURL)
                        let ciImage = image.tiffRepresentation.flatMap { CIImage(data: $0) }
                        let oriented = Self.orientedToTarget(
                            ciImage: ciImage, nsImage: nil,
                            from: orientation, to: targetOrientation
                        )
                        return (image: image, ciImage: oriented.ciImage)
                    }
                    return (image: nil, ciImage: nil)
                }.value
                let phase1Elapsed = ContinuousClock.now - phase1Start

                guard !Task.isCancelled else { return }

                // Thumbnail fallback needs no correction either — thumbnails are
                // kept rotated to match the in-memory orientation.
                if let image = previewSource.image {
                    sourceImage = image
                    sourceCIImage = previewSource.ciImage
                    editLog.info("[\(filename)] Phase 1: preview in \(phase1Elapsed) (\(image.size.width)x\(image.size.height))")
                } else {
                    let thumbnail = await browserViewModel.thumbnailService.loadThumbnail(for: selectedImageURL)
                    guard !Task.isCancelled else { return }
                    sourceImage = thumbnail
                    sourceCIImage = thumbnail?.tiffRepresentation.flatMap { CIImage(data: $0) }
                    editLog.info("[\(filename)] Phase 1: thumbnail fallback in \(phase1Elapsed)")
                }

                // Upload Phase 1 preview to Metal for immediate interactive editing.
                // sourceCIImage is already target-oriented — no correction here.
                if let ci = sourceCIImage, let pipeline = metalPipeline {
                    await Task.detached(priority: .medium) {
                        pipeline.uploadSourceImage(ci, exifOrientation: targetOrientation)
                    }.value
                    guard !Task.isCancelled else { return }
                    syncViewportToMetal()
                }

                renderPreview()
                isLoadingPreview = false
                isDecodingFullResolution = true

                // Phase 2: Load full-resolution CIImage → Metal texture.
                // After upload, materialize sourceCIImage at screen resolution to release
                // the full-resolution CIImage graph (same strategy as RAW path).
                if let pipeline = metalPipeline {
                    let phase2Start = ContinuousClock.now
                    // Oriented to the in-memory target inside the task — see orientedToTarget.
                    let fullRes: CIImage? = await Task.detached(priority: .userInitiated) {
                        let decoded: (image: CIImage, orientation: Int)?
                        if let result = await FullScreenImageCache.loadHDRFullResolutionOffPoolWithOrientation(from: selectedImageURL) {
                            decoded = result
                        } else if let result = await FullScreenImageCache.loadFullResolutionOffPoolWithOrientation(from: selectedImageURL) {
                            decoded = (CIImage(cgImage: result.image), result.orientation)
                        } else {
                            decoded = nil
                        }
                        guard let decoded else { return nil }
                        return Self.orientedToTarget(
                            ciImage: decoded.image, nsImage: nil,
                            from: decoded.orientation, to: targetOrientation
                        ).ciImage
                    }.value

                    guard !Task.isCancelled else { return }

                    if let fullRes {
                        let fullResCIImage = fullRes
                        let extent = fullResCIImage.extent
                        editLog.info("[\(filename)] Phase 2: full-res decoded in \(ContinuousClock.now - phase2Start) (\(Int(extent.width))x\(Int(extent.height)))")

                        let uploadStart = ContinuousClock.now
                        // Already target-oriented from the decode task.
                        await Task.detached(priority: .medium) {
                            pipeline.uploadSourceImage(fullResCIImage, exifOrientation: targetOrientation)
                        }.value
                        guard !Task.isCancelled else { return }
                        editLog.info("[\(filename)] Phase 2: texture uploaded in \(ContinuousClock.now - uploadStart)")

                        // Materialize sourceCIImage at screen resolution to release the
                        // full-res CIImage graph. Metal texture holds full-res for editing.
                        let materialized: CIImage? = await Task.detached(priority: .medium) {
                            let maxDim = max(extent.width, extent.height)
                            let targetPx = previewMaxPixelSize
                            let scale = maxDim > targetPx * 1.5 ? targetPx / maxDim : 1.0
                            let downsampled = scale < 1.0
                                ? fullResCIImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                                : fullResCIImage
                            guard let cgImage = CameraRawApproximation.ciContext.createCGImage(
                                downsampled, from: downsampled.extent,
                                format: .RGBAh,
                                colorSpace: CameraRawApproximation.workingColorSpace
                            ) else { return nil }
                            return CIImage(cgImage: cgImage)
                        }.value
                        sourceCIImage = materialized ?? fullResCIImage

                        let totalPhase2 = ContinuousClock.now - phase2Start
                        editLog.info("[\(filename)] Phase 2: complete in \(totalPhase2)")
                    }

                    isDecodingFullResolution = false
                    syncViewportToMetal()
                    renderPreview()
                } else {
                    isDecodingFullResolution = false
                }
            }
        }
    }

    /// Pre-cache Metal textures for the previous and next RAW images in the background.
    /// Uses screen-resolution decode to limit memory (~50MB per texture vs ~260MB at full res).
    /// Runs at low priority so it doesn't compete with the current image's decode.
    private func precacheAdjacentRAWTextures(
        currentURL: URL,
        pipeline: MetalLivePreviewPipeline
    ) {
        let images = browserViewModel.visibleImages
        guard let currentIndex = browserViewModel.urlToVisibleIndex[currentURL] else { return }

        // RAW decode is HDR-state independent (always full EDR headroom), so precached
        // textures stay valid regardless of each neighbor's HDR edit mode.
        var adjacentRAWs: [(url: URL, targetOrientation: Int)] = []
        if currentIndex > 0 {
            let prev = images[currentIndex - 1]
            if SupportedImageFormats.isRaw(url: prev.url) {
                adjacentRAWs.append((prev.url, prev.exifOrientation))
            }
        }
        if currentIndex < images.count - 1 {
            let next = images[currentIndex + 1]
            if SupportedImageFormats.isRaw(url: next.url) {
                adjacentRAWs.append((next.url, next.exifOrientation))
            }
        }

        guard !adjacentRAWs.isEmpty else { return }
        let screenMaxPx = previewWorkingMaxPixelSize
        editLog.info("[\(currentURL.lastPathComponent)] precacheAdjacent: \(adjacentRAWs.map(\.url.lastPathComponent)) at \(Int(screenMaxPx))px")

        adjacentRAWPrecacheTask?.cancel()
        adjacentRAWPrecacheTask = Task.detached(priority: .background) {
            for (url, neighborOrientation) in adjacentRAWs {
                guard !Task.isCancelled else {
                    editLog.info("[\(url.lastPathComponent)] precache: cancelled")
                    return
                }
                let start = ContinuousClock.now
                // Use the same flat CIRAWFilter decode as Phase 2 so the precached
                // texture matches the final render (no auto-boost / tone mismatch).
                // Decode straight to screen resolution (don't decode full sensor then
                // shrink). Read the tag adjacent to the decode (see Phase 2).
                let fileOrientation = FullScreenImageCache.fileEXIFOrientation(at: url)
                guard let rawResult = FullScreenImageCache.loadRAWImage(
                    from: url, draftMode: false, maxPixelSize: screenMaxPx
                ) else {
                    editLog.info("[\(url.lastPathComponent)] precache: decode failed")
                    continue
                }
                // Textures are target-oriented (see orientedToTarget) — a neighbor
                // rotated in the browser may have a pending orientation write.
                let oriented = Self.orientedToTarget(
                    ciImage: rawResult.image, nsImage: nil,
                    from: fileOrientation, to: neighborOrientation
                ).ciImage ?? rawResult.image
                guard !Task.isCancelled else {
                    editLog.info("[\(url.lastPathComponent)] precache: cancelled after decode")
                    return
                }
                let ciImage = FullScreenImageCache.downsample(oriented, maxPixelSize: screenMaxPx)
                pipeline.precacheTexture(
                    for: url, ciImage: ciImage,
                    neutralTemperature: rawResult.neutralTemperature,
                    neutralTint: rawResult.neutralTint
                )
                let elapsed = ContinuousClock.now - start
                editLog.info("[\(url.lastPathComponent)] precache: done in \(elapsed)")
            }
        }
    }

    /// Rotate the already-loaded source in place by the `from → to` orientation delta and
    /// re-upload it, instead of re-decoding the file. The retained source is known-good at
    /// `from`, so applying exactly the `from → to` correction yields a single, correct step —
    /// sidestepping the ImageIO re-decode that double-applies the rotation for non-RAW files
    /// (whose EXIF tag is rewritten on rotate). Full resolution is dropped and re-fetched
    /// lazily on the next zoom, matching the normal load path.
    private func rotateSourceInPlace(from: Int, to: Int) {
        let (rotatedCI, rotatedNS) = Self.orientedToTarget(
            ciImage: sourceCIImage, nsImage: sourceImage, from: from, to: to
        )
        sourceCIImage = rotatedCI
        sourceImage = rotatedNS
        previewSession.recordLoadedOrientation(to)
        // Aspect ratio swapped (landscape ↔ portrait) — re-fit and re-fetch full-res on zoom.
        isEditFullResLoaded = false
        editFullResTask?.cancel()
        editFullResTask = nil
        resetCropZoom()
        resetEditZoom()

        guard let ci = rotatedCI, let pipeline = metalPipeline else {
            renderPreview()
            return
        }
        previewTask?.cancel()
        previewTask = Task {
            await Task.detached(priority: .userInitiated) {
                pipeline.uploadSourceImage(ci, exifOrientation: to)
            }.value
            guard !Task.isCancelled else { return }
            syncViewportToMetal()
            renderPreview()
        }
    }

    /// Phase 2 decodes the RAW at screen resolution, which is sharp at fit-to-view but
    /// soft when the user zooms in to pixel-peep. When zoomed past 100%, lazily re-decode
    /// the current image at full sensor resolution and swap the Metal source texture.
    /// Mirrors FullScreenImageView.loadFullResIfNeeded(). One-shot per image (reset on
    /// navigation); non-RAW images already load full-res in Phase 2 and short-circuit here.
    private func loadFullResEditTextureIfNeeded() {
        guard editZoomScale > 1.0 else { return }
        guard !isEditFullResLoaded, editFullResTask == nil else { return }
        // Don't compete with the in-flight Phase 2 decode of the same file; Phase 2's
        // completion re-invokes this if the user is still zoomed in.
        guard !isDecodingFullResolution else { return }
        guard let url = selectedImageURL,
              let pipeline = metalPipeline, pipeline.hasSourceTexture,
              let texSize = pipeline.sourceTextureSize else { return }

        // Only worth a re-decode if the source has materially more detail than the
        // current (screen-res) texture. Match loadRAWImage's 1.5× slack.
        let texMax = max(texSize.width, texSize.height)
        guard let nativeMax = FullScreenImageCache.nativeLongestSide(of: url),
              nativeMax > texMax * 1.5 else {
            isEditFullResLoaded = true   // already effectively full-res — don't retry
            return
        }

        let targetOrientation = selectedImageOrientation
        let isRaw = SupportedImageFormats.isRaw(url: url)
        let filename = url.lastPathComponent
        let previewSessionGeneration = previewSession.sessionGeneration
        editLog.info("[\(filename)] zoom upgrade: decoding full-res (native \(Int(nativeMax))px, tex \(Int(texMax))px)")

        editFullResTask = Task {
            let start = ContinuousClock.now
            let fullRes: CIImage? = await Task.detached(priority: .userInitiated) {
                let fileOrientation = FullScreenImageCache.fileEXIFOrientation(at: url)
                var decoded: CIImage?
                if isRaw {
                    // nil maxPixelSize → full sensor resolution.
                    decoded = FullScreenImageCache.loadRAWImage(from: url, draftMode: false)?.image
                } else {
                    decoded = await FullScreenImageCache.loadHDRFullResolutionOffPool(from: url)
                    if decoded == nil,
                       let cgImage = await FullScreenImageCache.loadFullResolutionOffPool(from: url) {
                        decoded = CIImage(cgImage: cgImage)
                    }
                }
                guard let decoded else { return nil }
                return Self.orientedToTarget(
                    ciImage: decoded, nsImage: nil,
                    from: fileOrientation, to: targetOrientation
                ).ciImage ?? decoded
            }.value

            guard !Task.isCancelled, selectedImageURL == url, let fullRes else {
                previewSession.finishFullResolutionUpgrade(
                    sessionGeneration: previewSessionGeneration
                )
                return
            }
            await Task.detached(priority: .medium) {
                pipeline.uploadSourceImage(fullRes, exifOrientation: targetOrientation)
            }.value
            guard !Task.isCancelled, selectedImageURL == url else {
                previewSession.finishFullResolutionUpgrade(
                    sessionGeneration: previewSessionGeneration
                )
                return
            }
            isEditFullResLoaded = true
            previewSession.finishFullResolutionUpgrade(
                sessionGeneration: previewSessionGeneration
            )
            syncViewportToMetal()
            renderPreview()
            editLog.info("[\(filename)] zoom upgrade: full-res texture uploaded in \(ContinuousClock.now - start)")
        }
    }

    private func updateDisplayGamut() {
        scopeViewModel.displayGamut = isHDREnabled
            ? settingsViewModel.exportColorGamutHDR
            : settingsViewModel.exportColorGamutSDR
    }

    private func updateGamutClipMode() {
        updateDisplayGamut()
        guard let pipeline = metalPipeline else { return }
        if scopeViewModel.showClippedGamut {
            switch scopeViewModel.targetGamut {
            case .sRGB:      pipeline.gamutClipMode = 1
            case .displayP3: pipeline.gamutClipMode = 2
            case .rec2020:   pipeline.gamutClipMode = 3
            case .adobeRGB:  pipeline.gamutClipMode = 4
            }
        } else {
            pipeline.gamutClipMode = 0
        }
        pipeline.updateParams(settingsForPipeline(metadataViewModel.editingMetadata.cameraRaw))
        metalCoordinator.requestRedraw()
    }

    /// Returns the transient coordinator's render-only projection of the editable settings. The
    /// sticky section owner supplies a value snapshot so neither owner can mutate the other's state.
    private func settingsForPipeline(_ settings: CameraRawSettings?) -> CameraRawSettings? {
        let isRawSource = selectedImageURL.map { SupportedImageFormats.isRaw(url: $0) } ?? false
        return transientPreview.settingsForPipeline(
            settings,
            isRawSource: isRawSource,
            sectionMutes: sectionMutes.snapshot
        )
    }

    /// Connect (or disconnect) the clean-feed mirror to this editor's Metal pipeline.
    /// When connected, the feed pipeline shares the source texture and receives every
    /// `updateParams` so the second display tracks edits live. Called on edit-view
    /// appear and whenever the feed is toggled while editing.
    private func updateCleanFeedMirror(enabled: Bool) {
        guard let pipeline = metalPipeline else { return }
        if enabled, let feed = cleanFeedController.feedPipeline {
            pipeline.mirror = feed
            feed.asShotTemperature = pipeline.asShotTemperature
            feed.asShotTint = pipeline.asShotTint
            feed.gamutClipMode = pipeline.gamutClipMode
            pipeline.shareSourceTexture(with: feed)
            pipeline.onParamsChanged = { [hooks = cleanFeedController.hooks] in hooks.redraw?() }
            // Seed the feed with the current parameters + still, then redraw.
            renderPreview()
        } else {
            pipeline.mirror = nil
            pipeline.onParamsChanged = nil
            cleanFeedController.useEditPipeline = false
            cleanFeedController.feedPipeline?.clearSourceTexture()
        }
    }

    /// Push the current editor display state to the clean-feed window. The compute
    /// path (`useEditPipeline`) is used whenever the editor itself renders via Metal
    /// — i.e. a source texture exists and we're not showing "before"/muted, where the
    /// editor falls back to the CIImage. In those fallback cases the feed shows
    /// `displayCIImage` (aspect-fit on black) instead.
    private func syncCleanFeed() {
        guard cleanFeedController.editModeActive else { return }
        cleanFeedController.feedImage = displayCIImage
        cleanFeedController.isHDR = isHDREnabled
        cleanFeedController.useEditPipeline =
            (metalPipeline?.hasSourceTexture == true) && !isShowingBefore && !isMutingDevelop
        // Reflect the committed crop on the feed, but freeze updates while the crop tool is
        // active so the feed only reframes once the crop is confirmed and the tool closes.
        if !showCropControls, let imageSize = currentImageSize {
            let crop = activeCrop
            cleanFeedController.feedCrop = CleanFeedController.FeedCrop(
                left: crop.left, top: crop.top, right: crop.right, bottom: crop.bottom,
                angle: activeCropAngle, imageSize: imageSize
            )
        }
        cleanFeedController.requestFeedRedraw()
    }

    private func renderPreview() {
        updateDisplayGamut()
        syncCleanFeed()
        let renderStart = ContinuousClock.now
        guard let sourceCIImage else {
            previewCIImage = nil
            previewRender.publishFallback(
                sourceImage,
                isHDR: isHDREnabled,
                scopePublisher: publishDevelopPreviewToScope
            )
            return
        }

        let settings: CameraRawSettings? = {
            // "Before" still needs the SDR output tonemap for RAW sources so the
            // unedited baseline matches the previous SDR decode appearance.
            if isShowingBefore { return settingsForPipeline(nil) }
            var s = metadataViewModel.editingMetadata.cameraRaw
            if let asShot = asShotWhiteBalance {
                s?.asShotNeutralTemperature = Double(asShot.temperature)
                s?.asShotNeutralTint = Double(asShot.tint)
            }
            return settingsForPipeline(s)
        }()

        if isDevelopComparisonActive {
            scheduleDevelopComparisonRender()
        }

        // Keep Metal scope coordinator's crop region up to date
        if let coordinator = scopeViewModel.metalScopeCoordinator {
            let crop = activeCrop
            coordinator.cropLeft = Float(crop.left)
            coordinator.cropTop = Float(crop.top)
            coordinator.cropRight = Float(crop.right)
            coordinator.cropBottom = Float(crop.bottom)
        }

        // During drag: Metal update already handled by EditSlider.onDragValueChanged
        // (direct callback that bypasses SwiftUI body re-evaluation delay).
        // Only handle scope updates here.
        if isDraggingEditSlider {
            let elapsed = ContinuousClock.now - renderStart
            editLog.debug("renderPreview: drag path (\(elapsed))")
            // Metal scope renders automatically via continuous MTKView — skip CPU scope
            if scopeViewModel.metalScopePipeline == nil {
                updateScopeDuringDrag()
            }
            return
        }

        // Full render: update Metal compute params + request redraw.
        if let pipeline = metalPipeline, pipeline.hasSourceTexture {
            pipeline.updateParams(settings)
            syncViewportToMetal()
            // Metal overlay is only used during active drags — SwiftUI handles static display
            pipeline.updateOverlayParams(geometry: nil, visible: false)
            scopeViewModel.metalScopeCoordinator?.requestRedraw()
        }
        if lockedCropImageRect != nil {
            editLog.debug("renderPreview: crop interaction path (full-res Metal, skip CGImage)")
            return
        }

        editLog.debug("renderPreview: full path (CGImage generation)")

        // On release / initial load: produce CGImage for scope display and export
        let fullSource = sourceCIImage
        let fallback = sourceImage
        let orientation = selectedImageOrientation

        let hdr = isHDREnabled
        previewRender.requestRender(
            fallback: fallback,
            isHDR: hdr,
            operation: {
                await Task.detached(priority: .userInitiated) { () -> DevelopPreviewRenderCoordinator.Output? in
                    let output = CameraRawApproximation.apply(
                        to: fullSource,
                        settings: settings,
                        exifOrientation: orientation
                    )
                    let ctx = CameraRawApproximation.ciContext
                    guard let cgImage = ctx.createCGImage(
                        output,
                        from: output.extent,
                        format: .RGBAh,
                        colorSpace: CameraRawApproximation.workingColorSpace
                    ) else {
                        return nil
                    }
                    let nsImage = NSImage(
                        cgImage: cgImage,
                        size: NSSize(width: cgImage.width, height: cgImage.height)
                    )

                    // Generate cropped CGImage for scope display
                    let cropped = CameraRawApproximation.applyCrop(
                        to: output, originalExtent: fullSource.extent,
                        settings: settings, exifOrientation: orientation
                    )
                    let scopeCGImage: CGImage?
                    if cropped !== output {
                        scopeCGImage = ctx.createCGImage(
                            cropped, from: cropped.extent,
                            format: .RGBAh,
                            colorSpace: CameraRawApproximation.workingColorSpace
                        )
                    } else {
                        scopeCGImage = nil
                    }

                    return DevelopPreviewRenderCoordinator.Output(
                        previewImage: nsImage,
                        scopeImage: scopeCGImage ?? cgImage
                    )
                }.value
            },
            scopePublisher: publishDevelopPreviewToScope
        )
    }

    private func publishDevelopPreviewToScope(_ image: CGImage?, isHDR: Bool) {
        var userInfo: [String: Any] = ["isHDR": isHDR]
        userInfo["cgImage"] = image
        NotificationCenter.default.post(
            name: .scopeSourceImageDidChange,
            object: nil,
            userInfo: userInfo
        )
    }

    private var defaultDevelopComparisonTarget: ImageFile? {
        guard let selectedImageURL else { return nil }
        return DevelopComparisonSelectionResolver.target(
            in: browserViewModel.visibleImages,
            currentURL: selectedImageURL
        )
    }

    private func openDevelopComparison(with target: ImageFile) {
        guard target.url != selectedImageURL,
              SupportedImageFormats.isSupported(url: target.url) else { return }
        if showCropControls {
            toggleCropControls()
        }
        developComparison.openImageComparison(target: target)
        scheduleDevelopComparisonRender()
    }

    private func beginDevelopVersionComparison(with target: DevelopVersionComparisonTarget) {
        guard resolvedDevelopVersionComparisonTarget(target) != nil else { return }
        if showCropControls {
            toggleCropControls()
        }
        developComparison.openVersionComparison(target: target)
        scheduleDevelopComparisonRender()
    }

    private func closeDevelopComparison() {
        developComparison.close()
    }

    private func scheduleDevelopComparisonRender() {
        developComparison.cancelRender()
        guard isDevelopComparisonActive,
              let current = selectedImage,
              let sourceCIImage else { return }

        if let versionTarget = developVersionComparisonTarget {
            scheduleDevelopVersionComparisonRender(
                current: current,
                sourceImage: sourceCIImage,
                target: versionTarget
            )
            return
        }

        var settings = metadataViewModel.editingMetadata.cameraRaw
        if let asShotWhiteBalance {
            settings?.asShotNeutralTemperature = Double(asShotWhiteBalance.temperature)
            settings?.asShotNeutralTint = Double(asShotWhiteBalance.tint)
        }
        let liveSettings = settingsForPipeline(settings)
        let renderToken = FullScreenImageCache.renderToken(
            settings: liveSettings,
            isEdited: true
        ) ?? "live-unedited"
        let existingRevision = developComparisonLiveSource?.source.revision
        let maxPixelSize = min(max(previewWorkingMaxPixelSize, 2_048), 4_096)

        developComparison.renderImage {
            try await ComparisonRenderService().renderLiveEdit(
                imageFile: current,
                sourceImage: sourceCIImage,
                settings: liveSettings,
                renderToken: renderToken,
                revision: existingRevision,
                maxPixelSize: maxPixelSize
            )
        }
    }

    private func scheduleDevelopVersionComparisonRender(
        current: ImageFile,
        sourceImage: CIImage,
        target: DevelopVersionComparisonTarget
    ) {
        guard let targetValue = resolvedDevelopVersionComparisonTarget(target) else {
            closeDevelopComparison()
            return
        }

        let currentSettings = versionComparisonSettings(
            metadataViewModel.editingMetadata.cameraRaw
        )
        let targetSettings = versionComparisonSettings(targetValue.settings)
        let currentToken = FullScreenImageCache.renderToken(
            settings: currentSettings,
            isEdited: true
        ) ?? "primary-unedited"
        let targetToken = FullScreenImageCache.renderToken(
            settings: targetSettings,
            isEdited: true
        ) ?? "primary-unedited"
        let currentRepresentation: ComparisonRepresentation
        if let activeVersion = activeNamedDevelopVersion {
            currentRepresentation = .namedVersion(
                id: activeVersion.id,
                name: activeVersion.name,
                renderToken: currentToken
            )
        } else {
            currentRepresentation = .primary(renderToken: currentToken)
        }
        let targetRepresentation: ComparisonRepresentation
        switch target {
        case .primary:
            targetRepresentation = .primary(renderToken: targetToken)
        case let .named(id):
            targetRepresentation = .namedVersion(
                id: id,
                name: targetValue.name,
                renderToken: targetToken
            )
        }

        let existingRevision = developVersionRevision
            ?? developComparisonLiveSource?.source.revision
        let existingRightSource = developVersionComparisonRightSource.flatMap { source in
            source.source.representation == targetRepresentation ? source : nil
        }
        let maxPixelSize = min(max(previewWorkingMaxPixelSize, 2_048), 4_096)
        developComparison.renderVersion(target: target) {
            let service = ComparisonRenderService()
            let left = try await service.renderLiveEdit(
                imageFile: current,
                sourceImage: sourceImage,
                settings: currentSettings,
                renderToken: currentToken,
                representation: currentRepresentation,
                revision: existingRevision,
                maxPixelSize: maxPixelSize
            )
            let right: ComparisonRenderedSource
            if let existingRightSource {
                right = existingRightSource
            } else {
                right = try await service.renderLiveEdit(
                    imageFile: current,
                    sourceImage: sourceImage,
                    settings: targetSettings,
                    renderToken: targetToken,
                    representation: targetRepresentation,
                    revision: left.source.revision,
                    maxPixelSize: maxPixelSize
                )
            }
            return .init(live: left, target: right)
        }
    }

    private func resolvedDevelopVersionComparisonTarget(
        _ target: DevelopVersionComparisonTarget
    ) -> (name: String, settings: CameraRawSettings?)? {
        switch target {
        case .primary:
            return ("Primary (XMP)", primaryDevelopSettings)
        case let .named(id):
            guard let version = developVersionCatalog?.versions.first(where: { $0.id == id }) else {
                return nil
            }
            return (version.name, version.snapshot.settings)
        }
    }

    /// Version comparison renders the stored version itself, independent of temporary section
    /// mute/solo controls, while retaining the decoder state required for a faithful RAW preview.
    private func versionComparisonSettings(
        _ settings: CameraRawSettings?
    ) -> CameraRawSettings? {
        let isRawSource = selectedImageURL.map { SupportedImageFormats.isRaw(url: $0) } ?? false
        guard var result = settings else {
            guard isRawSource else { return nil }
            var tonemapOnly = CameraRawSettings()
            tonemapOnly.sourceHasHDRHeadroom = true
            return tonemapOnly
        }
        if let asShotWhiteBalance {
            result.asShotNeutralTemperature = Double(asShotWhiteBalance.temperature)
            result.asShotNeutralTint = Double(asShotWhiteBalance.tint)
        }
        result.sourceHasHDRHeadroom = isRawSource ? true : nil
        return result
    }

    private func updateScopeDuringDrag() {
        let now = ContinuousClock.now
        let interval = Duration.milliseconds(100)
        if now - lastScopeUpdateTime >= interval {
            lastScopeUpdateTime = now
            performScopeUpdate()
        } else {
            scopeThrottleTask?.cancel()
            let remaining = interval - (now - lastScopeUpdateTime)
            scopeThrottleTask = Task {
                try? await Task.sleep(for: remaining)
                guard !Task.isCancelled else { return }
                lastScopeUpdateTime = .now
                performScopeUpdate()
            }
        }
    }

    private func performScopeUpdate() {
        guard let sourceCIImage else { return }
        let settings: CameraRawSettings? = {
            var s = metadataViewModel.editingMetadata.cameraRaw
            if let asShot = asShotWhiteBalance {
                s?.asShotNeutralTemperature = Double(asShot.temperature)
                s?.asShotNeutralTint = Double(asShot.tint)
            }
            return s
        }()
        let hdr = isHDREnabled
        let orientation = selectedImageOrientation

        let maxDim: CGFloat = 360
        let extent = sourceCIImage.extent
        let scale = min(maxDim / extent.width, maxDim / extent.height, 1.0)
        let small = sourceCIImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let filtered = CameraRawApproximation.apply(to: small, settings: settings, exifOrientation: orientation)
        let scopeSource = CameraRawApproximation.applyCrop(
            to: filtered, originalExtent: small.extent,
            settings: settings, exifOrientation: orientation
        )

        scopeThrottleTask?.cancel()
        scopeThrottleTask = Task {
            let cgImage = await Task.detached(priority: .utility) {
                CameraRawApproximation.ciContext.createCGImage(
                    scopeSource,
                    from: scopeSource.extent,
                    format: .RGBAh,
                    colorSpace: CameraRawApproximation.workingColorSpace
                )
            }.value
            guard !Task.isCancelled, let cgImage else { return }
            NotificationCenter.default.post(
                name: .scopeSourceImageDidChange,
                object: nil,
                userInfo: ["cgImage": cgImage, "isHDR": hdr]
            )
        }
    }

    private func commitEditAdjustments() {
        if developVersionCatalog?.activeVersionID != nil {
            syncCameraRawToImageFile()
            scheduleActiveDevelopVersionSave()
            return
        }

        guard metadataViewModel.hasChanges else { return }

        // Develop edits persist to the .xmp sidecar during editing — the source file is NEVER
        // rewritten in place by the editor. Embedding XMP into the source on every tweak races
        // with the full-res mmap decode (CGImageSourceCreateWithURL) and crashes; edits bake
        // into a file only on Export, which renders a separate output. RAW was already
        // sidecar-only; this makes non-RAW match. (Sidecar wins over embedded crs on reload.)
        let effectiveMode: MetadataWriteMode = .writeToXMPSidecar

        // Sync cameraRaw to ImageFile so the thumbnail reflects edits immediately
        syncCameraRawToImageFile()

        metadataViewModel.commitEdits(mode: effectiveMode) {
            onPendingStatusChanged?()
        }
    }

    /// Commit a develop RESET. Like `commitEditAdjustments` it writes the cleared state to the
    /// sidecar, but for a non-RAW source that still carries embedded `crs` (edited under the old
    /// in-file model, or imported from ACR) it also clears the file's embedded crs in one write
    /// — otherwise the empty sidecar crs would let the embedded edits resurface on reload (the
    /// load merge applies the sidecar's cameraRaw only when it's non-empty). Resets are rare and
    /// user-initiated, so this one-off file write carries negligible decode-race risk. RAW is
    /// never written to the file.
    private func commitDevelopReset() {
        if developVersionCatalog?.activeVersionID != nil {
            syncCameraRawToImageFile()
            scheduleActiveDevelopVersionSave()
            return
        }

        guard metadataViewModel.hasChanges else { return }
        syncCameraRawToImageFile()

        let sourceHasEmbeddedCRS: Bool = {
            guard let url = selectedImageURL, !SupportedImageFormats.isRaw(url: url),
                  let crs = metadataViewModel.embeddedMetadata?.cameraRaw else { return false }
            return !crs.isEmpty
        }()
        let mode: MetadataWriteMode = sourceHasEmbeddedCRS ? .writeToFileAndXMPSidecar : .writeToXMPSidecar

        metadataViewModel.commitEdits(mode: mode) {
            onPendingStatusChanged?()
        }
    }

    private func syncCameraRawToImageFile() {
        guard let url = selectedImageURL,
              let index = browserViewModel.urlToImageIndex[url] else { return }
        var newSettings = metadataViewModel.editingMetadata.cameraRaw
        // Propagate as-shot WB reference so thumbnail rendering computes the correct WB matrix
        if let asShot = asShotWhiteBalance {
            newSettings?.asShotNeutralTemperature = Double(asShot.temperature)
            newSettings?.asShotNeutralTint = Double(asShot.tint)
        }
        let oldSettings = browserViewModel.images[index].cameraRawSettings
        guard newSettings != oldSettings else { return }
        browserViewModel.images[index].cameraRawSettings = newSettings
        browserViewModel.images[index].hasDevelopEdits = newSettings?.hasEffectiveEdits == true
        browserViewModel.images[index].hasCropEdits = newSettings?.crop?.isEffectiveCrop == true
        browserViewModel.thumbnailService.invalidateEditedThumbnail(for: url)
        // The full-screen cache's edited render was baked under the old settings.
        browserViewModel.fullScreenImageCache.invalidateEditedImage(for: url)
        // Remember this image so its edited previews get pre-warmed on exit (see disappear handler).
        editedURLsThisSession.insert(url)
    }

    private func fittedImageRect(in containerSize: CGSize, imageSize: CGSize) -> CGRect {
        guard containerSize.width > 0, containerSize.height > 0, imageSize.width > 0, imageSize.height > 0 else {
            return .zero
        }
        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        let x = (containerSize.width - width) * 0.5
        let y = (containerSize.height - height) * 0.5
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Computes a smaller image rect so that the rotated bounding box fits within the view.
    private func fittedImageRectForRotation(in containerSize: CGSize, imageSize: CGSize, angleDegrees: Double) -> CGRect {
        guard containerSize.width > 0, containerSize.height > 0, imageSize.width > 0, imageSize.height > 0 else {
            return .zero
        }
        let theta = abs(angleDegrees) * Double.pi / 180.0
        let cosT = cos(theta)
        let sinT = sin(theta)
        let rotBoundsW = imageSize.width * cosT + imageSize.height * sinT
        let rotBoundsH = imageSize.width * sinT + imageSize.height * cosT
        let scale = min(containerSize.width / rotBoundsW, containerSize.height / rotBoundsH)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        let x = (containerSize.width - width) * 0.5
        let y = (containerSize.height - height) * 0.5
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Scales and positions the image so the crop region fills the view.
    /// `handlePadding` is non-zero only while the crop controls are visible.
    /// The image may extend beyond the view bounds. The crop rectangle will be centered in the view.
    private func cropFittedImageRect(
        in containerSize: CGSize,
        imageSize: CGSize,
        crop: NormalizedCropRegion,
        angleDegrees: Double,
        zoom: CGFloat = 1.0,
        handlePadding: CGFloat = 0
    ) -> CGRect {
        guard containerSize.width > 0, containerSize.height > 0, imageSize.width > 0, imageSize.height > 0 else {
            return .zero
        }

        let availW = max(containerSize.width - handlePadding * 2, 1)
        let availH = max(containerSize.height - handlePadding * 2, 1)

        // The stored region is the upright crop — its dimensions are the actual crop dims.
        let actualW = crop.width * imageSize.width
        let actualH = crop.height * imageSize.height

        // Scale so actual crop fills available area, then apply zoom
        let baseScale = min(availW / max(actualW, 1), availH / max(actualH, 1))
        let scale = baseScale * zoom
        let imgW = imageSize.width * scale
        let imgH = imageSize.height * scale

        // Position so crop center maps to view center
        // Crop center offset from image center in scaled image coords
        let imgCropOffX = (crop.centerX - 0.5) * imgW
        let imgCropOffY = (crop.centerY - 0.5) * imgH

        // Rotate center offset by view rotation (-angle)
        let viewAngle = -angleDegrees * Double.pi / 180.0
        let cosV = cos(viewAngle)
        let sinV = sin(viewAngle)
        let viewCropOffX = imgCropOffX * cosV - imgCropOffY * sinV
        let viewCropOffY = imgCropOffX * sinV + imgCropOffY * cosV

        // Image center = view center minus crop offset
        let viewCenterX = containerSize.width * 0.5
        let viewCenterY = containerSize.height * 0.5
        let imgMidX = viewCenterX - viewCropOffX
        let imgMidY = viewCenterY - viewCropOffY

        return CGRect(
            x: imgMidX - imgW * 0.5,
            y: imgMidY - imgH * 0.5,
            width: imgW,
            height: imgH
        )
    }

    /// Computes the view-space crop rectangle for a given crop region, angle, and image rect.
    /// Matches CropOverlayView.viewCropRect (upright crop, rotated center offset).
    private func cropViewRect(crop: NormalizedCropRegion, angleDegrees: Double, imageRect: CGRect) -> CGRect {
        let A = -angleDegrees * Double.pi / 180.0
        let cosA = cos(A)
        let sinA = sin(A)

        // Crop center offset from image center in image-rect pixel units
        let imgCX = (crop.centerX - 0.5) * imageRect.width
        let imgCY = (crop.centerY - 0.5) * imageRect.height

        // Rotate center offset to view space
        let viewCX = imgCX * cosA - imgCY * sinA + imageRect.midX
        let viewCY = imgCX * sinA + imgCY * cosA + imageRect.midY

        // The stored region is the upright crop — its dimensions map directly.
        let actualW = crop.width * imageRect.width
        let actualH = crop.height * imageRect.height

        return CGRect(
            x: viewCX - actualW / 2,
            y: viewCY - actualH / 2,
            width: max(2, actualW),
            height: max(2, actualH)
        )
    }

    private var usesIncrementalWhiteBalance: Bool {
        // Non-RAW files always use incremental (relative) white balance
        if let url = selectedImageURL, !SupportedImageFormats.isRaw(url: url) {
            return true
        }
        return false
    }

    /// True when the image carries an imported Camera Raw white balance colder than we can
    /// represent. CITemperatureAndTint floors its neutral at 2000 K, but Adobe Camera RAW
    /// allows down to 1500 K. Such values render clamped to 2000 K; this drives a notice so
    /// the user knows the result differs from ACR.
    private var hasUnrepresentableWhiteBalance: Bool {
        guard let cameraRaw = metadataViewModel.editingMetadata.cameraRaw,
              cameraRaw.whiteBalance != "As Shot" else { return false }
        if usesIncrementalWhiteBalance {
            if let incremental = cameraRaw.incrementalTemperature {
                return Double(incremental) < Self.nonRawIncrementalTempRange.lowerBound
            }
        } else if let temperature = cameraRaw.temperature {
            return Double(temperature) < Self.minKelvin
        }
        return false
    }

    private var asShotTemperatureKelvin: Double {
        if let asShot = asShotWhiteBalance {
            return Double(asShot.temperature)
        }
        return 6500
    }

    private var asShotTintValue: Double {
        if let asShot = asShotWhiteBalance {
            return Double(asShot.tint)
        }
        return 0
    }

    private func updateCameraRaw(_ update: (inout CameraRawSettings) -> Void) {
        let oldSettings = metadataViewModel.editingMetadata.cameraRaw
        var cameraRaw = oldSettings ?? CameraRawSettings()
        update(&cameraRaw)
        cameraRaw.hasSettings = cameraRawHasEdits(cameraRaw) ? true : nil
        // Keep the settings alive while the crop tool is active (crop.hasCrop) even if
        // the crop is still a full-frame no-op — the overlay reads `crop.hasCrop` — but
        // an identity crop must NOT set hasSettings above, or it lights the edit badge.
        // HDR mode is display state rather than an adjustment, so it deliberately does not
        // contribute to `hasSettings`. It must still keep the Camera Raw container alive:
        // otherwise resetting the last adjustment (for example by double-clicking an exposure
        // slider) drops `hdrEditMode` with the container and silently switches the image to SDR.
        // Preserve both explicit values: `0` also prevents native/RAW auto-enable from turning
        // HDR back on after the user has deliberately disabled it.
        let shouldKeepSettings = cameraRawHasEdits(cameraRaw)
            || cameraRaw.crop?.hasCrop == true
            || cameraRaw.hdrEditMode != nil
        let newSettings = shouldKeepSettings ? cameraRaw : nil
        metadataViewModel.editingMetadata.cameraRaw = newSettings
        let editsNamedVersion = developVersionCatalog?.activeVersionID != nil
        if editsNamedVersion {
            metadataViewModel.hasChanges = false
        } else {
            metadataViewModel.markChanged()
        }

        editUndoManager.registerUndo(withTarget: metadataViewModel) { vm in
            vm.editingMetadata.cameraRaw = oldSettings
            if editsNamedVersion {
                vm.hasChanges = false
            } else {
                vm.markChanged()
            }
        }
    }

    private func cameraRawHasEdits(_ cameraRaw: CameraRawSettings) -> Bool {
        (cameraRaw.whiteBalance != nil && cameraRaw.whiteBalance != "As Shot")
            || cameraRaw.temperature != nil
            || cameraRaw.tint != nil
            || cameraRaw.incrementalTemperature != nil
            || cameraRaw.incrementalTint != nil
            || cameraRaw.exposure2012 != nil
            || cameraRaw.contrast2012 != nil
            || cameraRaw.highlights2012 != nil
            || cameraRaw.shadows2012 != nil
            || cameraRaw.whites2012 != nil
            || cameraRaw.blacks2012 != nil
            || cameraRaw.saturation != nil
            || cameraRaw.vibrance != nil
            || cameraRaw.globalDensity != nil
            || cameraRaw.sharpness != nil
            || cameraRaw.clarity2012 != nil
            || cameraRaw.dehaze != nil
            || cameraRaw.toneCurve != nil
            || (cameraRaw.crop?.isEffectiveCrop == true)
            || !(cameraRaw.localAdjustments?.isEmpty ?? true)
            || !(cameraRaw.watermarkLayers?.isEmpty ?? true)
            || !(cameraRaw.hslAdjustments?.isEmpty ?? true)
            || (cameraRaw.anonymizer?.isEmpty == false)
            || (cameraRaw.filmEmulation?.isEmpty == false)
            // Unknown ACR corrections are image-bound and must survive a
            // template application even when the template resets every edit
            // this app can model.
            || !(cameraRaw.unparsedMaskCorrections?.isEmpty ?? true)
    }

    private var hslAdjustmentsBinding: Binding<HSLAdjustments> {
        Binding(
            get: { metadataViewModel.editingMetadata.cameraRaw?.hslAdjustments ?? HSLAdjustments() },
            set: { newValue in
                updateCameraRaw { cameraRaw in
                    cameraRaw.hslAdjustments = newValue.isEmpty ? nil : newValue
                }
            }
        )
    }

    private func toneSliderBinding(_ keyPath: WritableKeyPath<CameraRawSettings, Int?>) -> Binding<Double> {
        Binding(
            get: { Double(metadataViewModel.editingMetadata.cameraRaw?[keyPath: keyPath] ?? 0) },
            set: { newValue in
                updateCameraRaw { cameraRaw in
                    // Neutral (0) means "no adjustment" — store nil, not 0, so resetting a
                    // slider to centre doesn't read as an edit (and light the edit badge).
                    let rounded = Int(newValue.rounded())
                    cameraRaw[keyPath: keyPath] = rounded == 0 ? nil : rounded
                }
            }
        )
    }

    private func filmSliderBinding(
        _ keyPath: WritableKeyPath<FilmEmulationSettings, Double?>,
        range: ClosedRange<Double> = 0...100
    ) -> Binding<Double> {
        Binding(
            get: {
                metadataViewModel.editingMetadata.cameraRaw?.filmEmulation?[keyPath: keyPath] ?? 0
            },
            set: { newValue in
                updateCameraRaw { cameraRaw in
                    var film = cameraRaw.filmEmulation ?? FilmEmulationSettings()
                    let rounded = min(max(newValue.rounded(), range.lowerBound), range.upperBound)
                    film[keyPath: keyPath] = rounded == 0 ? nil : rounded
                    cameraRaw.filmEmulation = film.isEmpty ? nil : film
                }
            }
        )
    }

    private func setFilmValue(
        _ settings: inout CameraRawSettings,
        keyPath: WritableKeyPath<FilmEmulationSettings, Double?>,
        value: Double,
        range: ClosedRange<Double> = 0...100
    ) {
        var film = settings.filmEmulation ?? FilmEmulationSettings()
        let rounded = min(max(value.rounded(), range.lowerBound), range.upperBound)
        film[keyPath: keyPath] = rounded == 0 ? nil : rounded
        settings.filmEmulation = film.isEmpty ? nil : film
    }

    /// Grain particle size. Kept separate from `filmSliderBinding` because it only has an
    /// effect while Grain amount is non-zero, so it defaults to a fine emulsion rather than 0
    /// and never zeroes itself out to nil (that would silently reset it to the default size).
    private var filmGrainCoarsenessBinding: Binding<Double> {
        Binding(
            get: {
                metadataViewModel.editingMetadata.cameraRaw?.filmEmulation?.resolvedGrainCoarseness
                    ?? FilmEmulationSettings().resolvedGrainCoarseness
            },
            set: { newValue in
                updateCameraRaw { cameraRaw in
                    var film = cameraRaw.filmEmulation ?? FilmEmulationSettings()
                    film.grainCoarseness = min(max(newValue.rounded(), 0), 100)
                    cameraRaw.filmEmulation = film
                }
            }
        )
    }

    private func setFilmGrainCoarseness(_ settings: inout CameraRawSettings, value: Double) {
        var film = settings.filmEmulation ?? FilmEmulationSettings()
        film.grainCoarseness = min(max(value.rounded(), 0), 100)
        settings.filmEmulation = film
    }

    private var toneCurveBinding: Binding<ToneCurve?> {
        Binding(
            get: { metadataViewModel.editingMetadata.cameraRaw?.toneCurve },
            set: { newValue in
                updateCameraRaw { cameraRaw in
                    cameraRaw.toneCurve = newValue
                }
            }
        )
    }

    private var exposureBinding: Binding<Double> {
        Binding(
            get: { metadataViewModel.editingMetadata.cameraRaw?.exposure2012 ?? 0.0 },
            set: { newValue in
                updateCameraRaw { cameraRaw in
                    // Neutral (0) means "no adjustment" — store nil so a reset-to-centre
                    // exposure doesn't read as an edit (and light the edit badge).
                    let rounded = (newValue * 100).rounded() / 100
                    cameraRaw.exposure2012 = rounded == 0 ? nil : rounded
                }
            }
        )
    }

    private var anonymizerAmountBinding: Binding<Double> {
        Binding(
            get: { metadataViewModel.editingMetadata.cameraRaw?.anonymizer?.amount ?? 0 },
            set: { newValue in
                updateCameraRaw { cameraRaw in
                    let clamped = min(max(newValue.rounded(), 0), 100)
                    if clamped <= 0 {
                        cameraRaw.anonymizer?.amount = nil
                        if cameraRaw.anonymizer?.isEmpty == true { cameraRaw.anonymizer = nil }
                    } else {
                        if cameraRaw.anonymizer == nil { cameraRaw.anonymizer = AnonymizerSettings() }
                        cameraRaw.anonymizer?.amount = clamped
                    }
                }
            }
        )
    }

    private var anonymizerEnabledBinding: Binding<Bool> {
        Binding(
            get: {
                AnonymizerToggleBehavior.isEnabled(
                    metadataViewModel.editingMetadata.cameraRaw?.anonymizer
                )
            },
            set: { newValue in
                updateCameraRaw { cameraRaw in
                    AnonymizerToggleBehavior.setEnabled(
                        newValue,
                        settings: &cameraRaw.anonymizer
                    )
                }
                commitEditAdjustments()
            }
        )
    }

    private var anonymizerBlackOutBinding: Binding<Bool> {
        Binding(
            get: { metadataViewModel.editingMetadata.cameraRaw?.anonymizer?.blackOut ?? false },
            set: { newValue in
                updateCameraRaw { cameraRaw in
                    if newValue {
                        if cameraRaw.anonymizer == nil { cameraRaw.anonymizer = AnonymizerSettings() }
                        cameraRaw.anonymizer?.blackOut = true
                    } else {
                        cameraRaw.anonymizer?.blackOut = nil
                        if cameraRaw.anonymizer?.isEmpty == true { cameraRaw.anonymizer = nil }
                    }
                }
                // A Toggle has no "drag end" — every flip is a discrete commit.
                commitEditAdjustments()
            }
        )
    }

    private var whiteBalanceTemperatureBinding: Binding<Double> {
        Binding(
            get: {
                if usesIncrementalWhiteBalance {
                    return Double(metadataViewModel.editingMetadata.cameraRaw?.incrementalTemperature ?? 0)
                }
                let value = Double(metadataViewModel.editingMetadata.cameraRaw?.temperature ?? Int(asShotTemperatureKelvin.rounded()))
                return min(max(value, Self.minKelvin), Self.maxKelvin)
            },
            set: { newValue in
                updateCameraRaw { cameraRaw in
                    cameraRaw.whiteBalance = "Custom"
                    if usesIncrementalWhiteBalance {
                        cameraRaw.incrementalTemperature = Int(newValue.rounded())
                    } else {
                        let clamped = min(max(newValue, Self.minKelvin), Self.maxKelvin)
                        cameraRaw.temperature = Int(clamped.rounded())
                    }
                }
            }
        )
    }

    private var whiteBalanceTemperatureLogBinding: Binding<Double> {
        Binding(
            get: {
                let kelvin = min(max(whiteBalanceTemperatureBinding.wrappedValue, Self.minKelvin), Self.maxKelvin)
                return normalizedLogScaleValue(forKelvin: kelvin)
            },
            set: { normalized in
                let kelvin = kelvinValue(forNormalizedLogScale: normalized)
                whiteBalanceTemperatureBinding.wrappedValue = kelvin
            }
        )
    }

    @ViewBuilder
    private var kelvinTemperatureSliderRow: some View {
        EditSliderRow(
            label: "Temperature (K)",
            value: whiteBalanceTemperatureLogBinding,
            range: 0...1,
            step: 0,
            gradientColors: [.blue, .yellow],
            formatter: { "\(Int($0.rounded()))" },
            displayValueTransform: { [self] in kelvinValue(forNormalizedLogScale: $0) },
            onEditingChanged: { editing in
                isDraggingEditSlider = editing
                if !editing {
                    commitEditAdjustments()
                }
            },
            onDragValueChanged: { dragValue in
                if let pipeline = metalPipeline, pipeline.hasSourceTexture {
                    var settings = metadataViewModel.editingMetadata.cameraRaw ?? CameraRawSettings()
                    let kelvin = kelvinValue(forNormalizedLogScale: dragValue)
                    settings.whiteBalance = "Custom"
                    settings.temperature = Int(kelvin.rounded())
                    pipeline.updateParams(settingsForPipeline(settings))
                    metalCoordinator.requestRedraw()
                }
            },
            onReset: {
                whiteBalanceTemperatureBinding.wrappedValue = asShotTemperatureKelvin
                commitEditAdjustments()
            },
            showReset: abs(whiteBalanceTemperatureBinding.wrappedValue - asShotTemperatureKelvin) > 1,
            resetHelp: "Reset to \(Int(asShotTemperatureKelvin))K"
        )
    }

    private func normalizedLogScaleValue(forKelvin kelvin: Double) -> Double {
        let clamped = min(max(kelvin, Self.minKelvin), Self.maxKelvin)
        let minLog = log(Self.minKelvin)
        let maxLog = log(Self.maxKelvin)
        return (log(clamped) - minLog) / (maxLog - minLog)
    }

    private func kelvinValue(forNormalizedLogScale normalized: Double) -> Double {
        let t = min(max(normalized, 0), 1)
        let minLog = log(Self.minKelvin)
        let maxLog = log(Self.maxKelvin)
        return exp(minLog + (maxLog - minLog) * t)
    }

    private var whiteBalanceTintBinding: Binding<Double> {
        Binding(
            get: {
                if usesIncrementalWhiteBalance {
                    return Double(metadataViewModel.editingMetadata.cameraRaw?.incrementalTint ?? 0)
                }
                return Double(metadataViewModel.editingMetadata.cameraRaw?.tint ?? Int(asShotTintValue.rounded()))
            },
            set: { newValue in
                updateCameraRaw { cameraRaw in
                    cameraRaw.whiteBalance = "Custom"
                    if usesIncrementalWhiteBalance {
                        cameraRaw.incrementalTint = Int(newValue.rounded())
                    } else {
                        cameraRaw.tint = Int(newValue.rounded())
                    }
                }
            }
        )
    }

    private var cropZoomBinding: Binding<Double> {
        Binding(
            get: { Double(cropZoomScale) },
            set: { cropZoomScale = CGFloat($0) }
        )
    }

    private var cropAngleBinding: Binding<Double> {
        Binding(
            get: { activeCropAngle },
            set: { newValue in
                updateCropAngle(newValue, commit: false)
            }
        )
    }

    /// Crop straightening is rendered by SwiftUI rather than the Metal parameter path.
    /// Keep the transient angle and fitted crop local while dragging so both crop control
    /// surfaces remain responsive without writing metadata at pointer-event frequency.
    private func updateCropAngleDragPreview(_ value: Double) {
        cropSession.updateAngleDragPreview(
            value,
            activeCrop: activeCrop,
            sourceAspectRatio: sourceAspectRatio
        )
    }

    private func resetCropAngle() {
        cropSession.cancelInteraction()
        cropAngleBinding.wrappedValue = 0
    }

    private func toggleCropControls() {
        let isActive = cropSession.toggleTool()
        if isActive {
            // Deselect mask and reset edit zoom when entering crop mode
            selectedLayer = .global
            metalPipeline?.updateOverlayParams(geometry: nil, visible: false)
            resetEditZoom()
        }
        if isActive && !isCropEnabled {
            // Showing controls — enable crop if not already active
            resetCropZoom()
            updateCameraRaw { cameraRaw in
                _ = cropSession.enableCropIfNeeded(in: &cameraRaw)
            }
            if cropAspectRatio != .free {
                applyAspectRatioToCrop(cropAspectRatio)
            }
            commitEditAdjustments()
        }
        if !isActive {
            // Reset zoom and unlock image rect when hiding controls
            // The crop editor renders with an identity viewport because its MTKView
            // is framed to the image. The confirmed-crop preview is pane-sized and
            // needs the Metal crop viewport immediately when the tool closes.
            syncViewportToMetal()
            // Crop tool deactivated — push the now-confirmed crop to the clean feed.
            syncCleanFeed()
        }
    }

    private func resetCrop() {
        updateCameraRaw { cameraRaw in
            _ = cropSession.resetCrop(in: &cameraRaw)
        }
        commitEditAdjustments()
        // Reset can be invoked from either crop control surface. Restore the normal
        // pane-sized Metal viewport immediately, just like finishing crop mode.
        syncViewportToMetal()
        // Crop cleared — refresh the clean feed back to the full frame.
        syncCleanFeed()
    }

    private func applyAspectRatioToCrop(_ ratio: CropAspectRatio) {
        guard isCropEnabled else { return }
        let targetRatio: Double?
        if ratio == .original {
            targetRatio = sourceAspectRatio > 0 ? sourceAspectRatio : nil
        } else {
            targetRatio = ratio.value
        }
        guard let targetRatio, targetRatio > 0 else { return }

        let current = activeCrop
        let resized = current.resizedToActualAspectRatio(
            targetRatio, angleDegrees: activeCropAngle, imageAspectRatio: sourceAspectRatio
        )
        updateCrop(resized, commit: true)
    }

    private func updateCrop(_ crop: NormalizedCropRegion, commit: Bool) {
        updateCameraRaw { cameraRaw in
            _ = cropSession.updateCrop(
                crop,
                sourceAspectRatio: sourceAspectRatio,
                orientation: selectedImageOrientation,
                commit: commit,
                in: &cameraRaw
            )
        }
        if commit {
            commitEditAdjustments()
        }
    }

    private func updateCropAngle(_ angle: Double, commit: Bool) {
        updateCameraRaw { cameraRaw in
            _ = cropSession.updateCropAngle(
                angle,
                sourceAspectRatio: sourceAspectRatio,
                orientation: selectedImageOrientation,
                commit: commit,
                in: &cameraRaw
            )
        }
        if commit {
            commitEditAdjustments()
        }
    }

    /// - Parameter settingsMutator: Applies the raw drag value to a CameraRawSettings copy
    ///   for direct Metal rendering without triggering SwiftUI observation.
    ///   When nil, the slider falls back to updating the binding directly during drag.
    @ViewBuilder
    private func sliderRow(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        gradientColors: [Color]? = nil,
        formatter: @escaping (Double) -> String,
        visibility: DevelopSlider? = nil,
        settingsMutator: ((inout CameraRawSettings, Double) -> Void)? = nil,
        onSliderEditingChanged: ((Bool) -> Void)? = nil,
        onReset: (() -> Void)? = nil,
        showReset: Bool? = nil
    ) -> some View {
        if visibility.map(settingsViewModel.isDevelopSliderVisible) ?? true {
            EditSliderRow(
                label: label,
                value: value,
                range: range,
                step: step,
                gradientColors: gradientColors,
                formatter: formatter,
                onEditingChanged: { editing in
                    isDraggingEditSlider = editing
                    onSliderEditingChanged?(editing)
                    if !editing {
                        commitEditAdjustments()
                    }
                },
                onDragValueChanged: settingsMutator.map { mutator in
                    { dragValue in
                        var settings = metadataViewModel.editingMetadata.cameraRaw ?? CameraRawSettings()
                        mutator(&settings, dragValue)
                        if let pipeline = metalPipeline, pipeline.hasSourceTexture {
                            pipeline.updateParams(settingsForPipeline(settings))
                            metalCoordinator.requestRedraw()
                        }
                    }
                },
                onReset: onReset.map { resetFn in
                    {
                        resetFn()
                        commitEditAdjustments()
                    }
                },
                showReset: showReset
            )
        }
    }

    // MARK: - Global Adjustment Sliders

    @ViewBuilder
    private var globalAdjustmentSliders: some View {
        ForEach(settingsViewModel.developSectionOrder) { section in
            developPanelSection(section)
        }
    }

    @ViewBuilder
    private func developPanelSection(_ section: DevelopPanelSection) -> some View {
        switch section {
        case .color:
            colorDevelopSection
        case .exposure:
            exposureDevelopSection
        case .detail:
            detailDevelopSection
        case .toneCurve:
            toneCurveDevelopSection
        case .hsl:
            hslDevelopSection
        case .anonymizer:
            anonymizerDevelopSection
        case .filmEmulation:
            filmDevelopSection
        }
    }

    @ViewBuilder
    private var colorDevelopSection: some View {
        // ── Color ──
        colorSectionHeader
        Divider()

        if usesIncrementalWhiteBalance {
            sliderRow(
                "WB Temp",
                value: whiteBalanceTemperatureBinding,
                range: Self.nonRawIncrementalTempRange,
                step: 1,
                gradientColors: [.blue, .yellow],
                formatter: signedIntString,
                settingsMutator: { settings, value in
                    settings.whiteBalance = "Custom"
                    settings.incrementalTemperature = Int(value.rounded())
                },
                onReset: {
                    whiteBalanceTemperatureBinding.wrappedValue = 0
                }
            )
        } else {
            kelvinTemperatureSliderRow
        }

        if hasUnrepresentableWhiteBalance {
            Label(
                "This image's Adobe Camera Raw white balance is colder than 2000 K, which isn't supported here. It's shown clamped to 2000 K.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }

        sliderRow(
            "Tint",
            value: whiteBalanceTintBinding,
            range: -150...150,
            step: 1,
            gradientColors: [.green, .pink],
            formatter: signedIntString,
            settingsMutator: { settings, value in
                settings.whiteBalance = "Custom"
                settings.tint = Int(value.rounded())
            },
            onReset: {
                whiteBalanceTintBinding.wrappedValue = asShotTintValue
            }
        )

        sliderRow("Saturation", value: toneSliderBinding(\.saturation), range: -100...100, step: 1, gradientColors: [.gray, .red], formatter: signedIntString, visibility: .saturation, settingsMutator: { $0.saturation = Int($1.rounded()) }, onReset: {
            toneSliderBinding(\.saturation).wrappedValue = 0
        })
        sliderRow("Vibrance", value: toneSliderBinding(\.vibrance), range: -100...100, step: 1, gradientColors: [.gray, .orange], formatter: signedIntString, visibility: .vibrance, settingsMutator: { $0.vibrance = Int($1.rounded()) }, onReset: {
            toneSliderBinding(\.vibrance).wrappedValue = 0
        })
        sliderRow("Density", value: toneSliderBinding(\.globalDensity), range: -100...100, step: 1, gradientColors: [.white, .black], formatter: signedIntString, visibility: .density, settingsMutator: { $0.globalDensity = Int($1.rounded()) }, onReset: {
            toneSliderBinding(\.globalDensity).wrappedValue = 0
        })
    }

    @ViewBuilder
    private var exposureDevelopSection: some View {
        // ── Exposure ──
        exposureSectionHeader
        Divider()

        sliderRow(
            "Exposure",
            value: exposureBinding,
            range: -5...5,
            step: 0.01,
            formatter: { signedDoubleString($0, precision: 2) },
            settingsMutator: { $0.exposure2012 = ($1 * 100).rounded() / 100 },
            onReset: {
                exposureBinding.wrappedValue = 0
            }
        )

        sliderRow("Contrast", value: toneSliderBinding(\.contrast2012), range: -100...100, step: 1, formatter: signedIntString, visibility: .contrast, settingsMutator: { $0.contrast2012 = Int($1.rounded()) }, onReset: {
            toneSliderBinding(\.contrast2012).wrappedValue = 0
        })
        sliderRow("Highlights", value: toneSliderBinding(\.highlights2012), range: -100...100, step: 1, formatter: signedIntString, visibility: .highlights, settingsMutator: { $0.highlights2012 = Int($1.rounded()) }, onReset: {
            toneSliderBinding(\.highlights2012).wrappedValue = 0
        })
        sliderRow("Shadows", value: toneSliderBinding(\.shadows2012), range: -100...100, step: 1, formatter: signedIntString, visibility: .shadows, settingsMutator: { $0.shadows2012 = Int($1.rounded()) }, onReset: {
            toneSliderBinding(\.shadows2012).wrappedValue = 0
        })
        sliderRow("Whites", value: toneSliderBinding(\.whites2012), range: -100...100, step: 1, formatter: signedIntString, visibility: .whites, settingsMutator: { $0.whites2012 = Int($1.rounded()) }, onReset: {
            toneSliderBinding(\.whites2012).wrappedValue = 0
        })
        sliderRow("Blacks", value: toneSliderBinding(\.blacks2012), range: -100...100, step: 1, formatter: signedIntString, visibility: .blacks, settingsMutator: { $0.blacks2012 = Int($1.rounded()) }, onReset: {
            toneSliderBinding(\.blacks2012).wrappedValue = 0
        })
    }

    @ViewBuilder
    private var detailDevelopSection: some View {
        if settingsViewModel.isDevelopSliderGroupVisible(.detail) {
            // ── Detail ──
            sectionHeader("Detail", isMuted: sectionMuteBinding(.detail), hasAdjustments: hasDetailAdjustments, onReset: resetDetailAdjustments)
                .padding(.top, 2)
            Divider()

            sliderRow("Sharpness", value: toneSliderBinding(\.sharpness), range: 0...150, step: 1, formatter: signedIntString, visibility: .sharpness, settingsMutator: { $0.sharpness = Int($1.rounded()) }, onReset: {
                toneSliderBinding(\.sharpness).wrappedValue = 0
            })
            sliderRow("Clarity", value: toneSliderBinding(\.clarity2012), range: -100...100, step: 1, formatter: signedIntString, visibility: .clarity, settingsMutator: { $0.clarity2012 = Int($1.rounded()) }, onReset: {
                toneSliderBinding(\.clarity2012).wrappedValue = 0
            })
            sliderRow("Dehaze", value: toneSliderBinding(\.dehaze), range: -100...100, step: 1, formatter: signedIntString, visibility: .dehaze, settingsMutator: { $0.dehaze = Int($1.rounded()) }, onReset: {
                toneSliderBinding(\.dehaze).wrappedValue = 0
            })
        }
    }

    @ViewBuilder
    private var toneCurveDevelopSection: some View {
        if settingsViewModel.isDevelopSliderVisible(.toneCurve) {
            // ── Tone Curve ──
            CurveEditorView(
                toneCurve: toneCurveBinding,
                isMuted: sectionMuteBinding(.toneCurve),
                onDragCurveChanged: { dragCurve in
                    if let pipeline = metalPipeline, pipeline.hasSourceTexture {
                        var settings = metadataViewModel.editingMetadata.cameraRaw ?? CameraRawSettings()
                        settings.toneCurve = dragCurve
                        pipeline.updateParams(settingsForPipeline(settings))
                        metalCoordinator.requestRedraw()
                    }
                },
                onEditingChanged: { editing in
                    isDraggingEditSlider = editing
                    if !editing {
                        commitEditAdjustments()
                    }
                },
                onMuteToggled: {
                    renderPreview()
                }
            )
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private var hslDevelopSection: some View {
        if settingsViewModel.isDevelopSliderVisible(.hsl) {
            // ── Hue / Saturation / Density ──
            sectionHeader("Hue / Saturation / Density", isMuted: sectionMuteBinding(.hsl), hasAdjustments: hasHSLAdjustments, onReset: resetHSLAdjustments)
                .padding(.top, 2)
            Divider()

            HSLAdjustmentView(
                adjustments: hslAdjustmentsBinding,
                onEditingChanged: { editing in
                    isDraggingEditSlider = editing
                },
                onDragChanged: { adjustments in
                    if let pipeline = metalPipeline, pipeline.hasSourceTexture {
                        var settings = metadataViewModel.editingMetadata.cameraRaw ?? CameraRawSettings()
                        settings.hslAdjustments = adjustments.isEmpty ? nil : adjustments
                        pipeline.updateParams(settingsForPipeline(settings))
                        metalCoordinator.requestRedraw()
                    }
                },
                onDragEnded: {
                    commitEditAdjustments()
                }
            )
        }
    }

    @ViewBuilder
    private var filmDevelopSection: some View {
        if settingsViewModel.isDevelopSliderGroupVisible(.film) {
            // ── Film Emulation ──
            sectionHeader(
                "Film Emulation",
                isMuted: sectionMuteBinding(.film),
                hasAdjustments: hasFilmAdjustments,
                onReset: resetFilmAdjustments
            )
            .padding(.top, 2)
            Divider()

            sliderRow(
                "Film Grain",
                value: filmSliderBinding(\.grain),
                range: 0...100,
                step: 1,
                formatter: { "\(Int($0.rounded()))" },
                visibility: .filmGrain,
                settingsMutator: { setFilmValue(&$0, keyPath: \.grain, value: $1) },
                onReset: { filmSliderBinding(\.grain).wrappedValue = 0 }
            )
            sliderRow(
                "Grain Size",
                value: filmGrainCoarsenessBinding,
                range: 0...100,
                step: 1,
                formatter: { "\(Int($0.rounded()))" },
                visibility: .filmGrainCoarseness,
                settingsMutator: { setFilmGrainCoarseness(&$0, value: $1) },
                onReset: { filmGrainCoarsenessBinding.wrappedValue = 35 },
                showReset: (metadataViewModel.editingMetadata.cameraRaw?.filmEmulation?.grainCoarseness).map { $0 != 35 } ?? false
            )
            .disabled((metadataViewModel.editingMetadata.cameraRaw?.filmEmulation?.grain ?? 0) <= 0)
            sliderRow(
                "Halation",
                value: filmSliderBinding(\.halation),
                range: 0...100,
                step: 1,
                formatter: { "\(Int($0.rounded()))" },
                visibility: .halation,
                settingsMutator: { setFilmValue(&$0, keyPath: \.halation, value: $1) },
                onReset: { filmSliderBinding(\.halation).wrappedValue = 0 }
            )
            sliderRow(
                "Bloom",
                value: filmSliderBinding(\.bloom),
                range: 0...100,
                step: 1,
                formatter: { "\(Int($0.rounded()))" },
                visibility: .bloom,
                settingsMutator: { setFilmValue(&$0, keyPath: \.bloom, value: $1) },
                onReset: { filmSliderBinding(\.bloom).wrappedValue = 0 }
            )
            sliderRow(
                "Vignette",
                value: filmSliderBinding(\.vignette, range: -100...100),
                range: -100...100,
                step: 1,
                formatter: { "\(Int($0.rounded()))" },
                visibility: .vignette,
                settingsMutator: { setFilmValue(&$0, keyPath: \.vignette, value: $1, range: -100...100) },
                onReset: { filmSliderBinding(\.vignette, range: -100...100).wrappedValue = 0 }
            )
            sliderRow(
                "Edge Blur",
                value: filmSliderBinding(\.edgeBlur),
                range: 0...100,
                step: 1,
                formatter: { "\(Int($0.rounded()))" },
                visibility: .edgeBlur,
                settingsMutator: { setFilmValue(&$0, keyPath: \.edgeBlur, value: $1) },
                onReset: { filmSliderBinding(\.edgeBlur).wrappedValue = 0 }
            )
        }
    }

    @ViewBuilder
    private var anonymizerDevelopSection: some View {
        if settingsViewModel.isDevelopSliderGroupVisible(.privacy) {
            // ── Anonymizer ──
            HStack(spacing: 6) {
                Text("Anonymizer")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .onTapGesture(count: 2) {
                        if hasAnonymizerAdjustments { resetAnonymizerAdjustments() }
                    }
                Toggle("Enable anonymizer", isOn: anonymizerEnabledBinding)
                    .labelsHidden()
                    .controlSize(.mini)
                    .help("Enable anonymizer at strength 30")
                Spacer()
                Button {
                    resetAnonymizerAdjustments()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!hasAnonymizerAdjustments)
                .help("Reset anonymizer")
            }
            .padding(.top, 2)
            Divider()

            sliderRow(
                "Anonymizer",
                value: anonymizerAmountBinding,
                range: 0...100,
                step: 1,
                formatter: { "\(Int($0.rounded()))" },
                visibility: .anonymizer,
                settingsMutator: { settings, value in
                    let clamped = min(max(value.rounded(), 0), 100)
                    if clamped <= 0 {
                        settings.anonymizer?.amount = nil
                        if settings.anonymizer?.isEmpty == true { settings.anonymizer = nil }
                    } else {
                        if settings.anonymizer == nil { settings.anonymizer = AnonymizerSettings() }
                        settings.anonymizer?.amount = clamped
                    }
                },
                onReset: {
                    anonymizerAmountBinding.wrappedValue = 0
                }
            )
            .disabled(!anonymizerEnabledBinding.wrappedValue || anonymizerBlackOutBinding.wrappedValue)

            Toggle("Black out", isOn: anonymizerBlackOutBinding)
                .toggleStyle(.checkbox)
                .disabled(!anonymizerEnabledBinding.wrappedValue)
                .help("Fully redact this region instead of the mosaic effect")
        }
    }

    // MARK: - Section Headers

    private func sectionMuteBinding(_ section: DevelopSectionMute) -> Binding<Bool> {
        Binding(
            get: { sectionMutes.isMuted(section) },
            set: { sectionMutes.setMuted($0, for: section) }
        )
    }

    private func sectionHeader(
        _ title: String,
        isMuted: Binding<Bool>,
        hasAdjustments: Bool = false,
        onReset: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .onTapGesture(count: 2) {
                    if hasAdjustments { onReset?() }
                }
            Spacer()
            Button {
                isMuted.wrappedValue.toggle()
                renderPreview()
            } label: {
                Image(systemName: isMuted.wrappedValue ? "eye.slash" : "eye")
                    .font(.system(size: 11))
                    .foregroundStyle(isMuted.wrappedValue ? .orange : .secondary)
            }
            .buttonStyle(.plain)
            .help(isMuted.wrappedValue ? "Show \(title.lowercased())" : "Hide \(title.lowercased())")
            if let onReset {
                Button {
                    onReset()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!hasAdjustments)
                .help("Reset \(title.lowercased())")
            }
        }
    }

    /// Color section header — like `sectionHeader("Color", …)` but with the white-balance
    /// eyedropper toggle next to the title (Camera Raw places the WB tool atop the panel).
    private var colorSectionHeader: some View {
        HStack(spacing: 6) {
            Text("Color")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .onTapGesture(count: 2) {
                    if hasColorAdjustments { resetColorAdjustments() }
                }
            Button {
                toggleWhiteBalancePicker()
            } label: {
                Image(systemName: "eyedropper.halffull")
                    .font(.system(size: 11))
                    .foregroundStyle(isPickingWhiteBalance ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canEditSingleImage || metalPipeline?.hasSourceTexture != true)
            .help("Set white balance from the image — click a neutral grey, or drag to average an area")
            Spacer()
            Button {
                sectionMutes.toggle(.color)
                renderPreview()
            } label: {
                Image(systemName: sectionMutes.isMuted(.color) ? "eye.slash" : "eye")
                    .font(.system(size: 11))
                    .foregroundStyle(sectionMutes.isMuted(.color) ? .orange : .secondary)
            }
            .buttonStyle(.plain)
            .help(sectionMutes.isMuted(.color) ? "Show color" : "Hide color")
            Button {
                resetColorAdjustments()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!hasColorAdjustments)
            .help("Reset color")
        }
    }

    private func toggleWhiteBalancePicker() {
        isPickingWhiteBalance.toggle()
        wbPickDragRect = nil
        // Picking samples the full-frame preview; the crop tool reframes the layout, so
        // close it first to keep the screen→image mapping the simple fitted viewport.
        if isPickingWhiteBalance, showCropControls {
            toggleCropControls()
        }
    }

    /// Map a preview-pane rectangle to source pixels, average it, and solve for the WB
    /// temperature/tint that neutralises that colour. Sampling + solve run off-main; the
    /// resulting values are applied back on the main actor.
    /// Map a preview-pane rectangle to a region of `sourceCIImage` (the pre-WB source the
    /// shader samples). Pane → viewport UV (`uv = origin + norm·size`, matching the shader),
    /// then UV (top-left origin) → CIImage extent (bottom-left origin) with a Y flip.
    private func sourceRegion(
        forPaneRect rect: CGRect, paneSize: CGSize,
        viewportOrigin vpOrigin: SIMD2<Float>, viewportSize vpSize: SIMD2<Float>
    ) -> CGRect? {
        guard let source = sourceCIImage, paneSize.width > 0, paneSize.height > 0 else { return nil }
        func uvX(_ x: CGFloat) -> Double { Double(vpOrigin.x) + Double(x / paneSize.width) * Double(vpSize.x) }
        func uvY(_ y: CGFloat) -> Double { Double(vpOrigin.y) + Double(y / paneSize.height) * Double(vpSize.y) }
        let uvMinX = min(max(uvX(rect.minX), 0), 1)
        let uvMaxX = min(max(uvX(rect.maxX), 0), 1)
        let uvMinY = min(max(uvY(rect.minY), 0), 1)   // top
        let uvMaxY = min(max(uvY(rect.maxY), 0), 1)   // bottom
        guard uvMaxX > uvMinX, uvMaxY > uvMinY else { return nil }
        let extent = source.extent
        return CGRect(
            x: extent.minX + uvMinX * extent.width,
            y: extent.minY + (1 - uvMaxY) * extent.height,
            width: (uvMaxX - uvMinX) * extent.width,
            height: (uvMaxY - uvMinY) * extent.height
        )
    }

    /// Synchronous averaged-colour probe for the eyedropper's live readout (debug HUD).
    /// Returns the same linear value that would be fed to the solver for this pane rect.
    private func probeLinearRGB(
        forPaneRect rect: CGRect, paneSize: CGSize,
        viewportOrigin vpOrigin: SIMD2<Float>, viewportSize vpSize: SIMD2<Float>
    ) -> SIMD3<Float>? {
        guard let source = sourceCIImage,
              let region = sourceRegion(forPaneRect: rect, paneSize: paneSize,
                                        viewportOrigin: vpOrigin, viewportSize: vpSize) else { return nil }
        return Self.averageLinearRGB(of: source, in: region)
    }

    private func performWhiteBalancePick(
        inPaneRect rect: CGRect, paneSize: CGSize,
        viewportOrigin vpOrigin: SIMD2<Float>, viewportSize vpSize: SIMD2<Float>
    ) {
        guard let source = sourceCIImage, let pipeline = metalPipeline, pipeline.hasSourceTexture,
              let region = sourceRegion(forPaneRect: rect, paneSize: paneSize,
                                        viewportOrigin: vpOrigin, viewportSize: vpSize) else { return }

        Task {
            let solved = await Task.detached(priority: .userInitiated) { () -> (temperature: Double, tint: Double)? in
                guard let rgb = Self.averageLinearRGB(of: source, in: region) else { return nil }
                return pipeline.solveWhiteBalance(forNeutralLinearRGB: rgb)
            }.value
            guard let solved else { return }
            applyPickedWhiteBalance(temperatureKelvin: solved.temperature, tint: solved.tint)
        }
    }

    private func applyPickedWhiteBalance(temperatureKelvin: Double, tint: Double) {
        let clampedTint = min(max(tint, -150), 150)
        updateCameraRaw { cameraRaw in
            cameraRaw.whiteBalance = "Custom"
            if usesIncrementalWhiteBalance {
                // Invert the non-RAW slope: temp = 6500 + incr * (5000 / 150).
                let incremental = (temperatureKelvin - 6500) * (150.0 / 5000.0)
                let range = Self.nonRawIncrementalTempRange
                cameraRaw.incrementalTemperature = Int(min(max(incremental, range.lowerBound), range.upperBound).rounded())
                cameraRaw.incrementalTint = Int(clampedTint.rounded())
            } else {
                let clampedTemp = min(max(temperatureKelvin, Self.minKelvin), Self.maxKelvin)
                cameraRaw.temperature = Int(clampedTemp.rounded())
                cameraRaw.tint = Int(clampedTint.rounded())
            }
        }
        commitEditAdjustments()
    }

    /// Average a region of a linear extended-sRGB CIImage to a single colour, returned in
    /// the same working space the WB matrix operates in.
    nonisolated private static func averageLinearRGB(of image: CIImage, in region: CGRect) -> SIMD3<Float>? {
        let clipped = region.intersection(image.extent)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1,
              let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: clipped), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else { return nil }
        var pixel = [Float](repeating: 0, count: 4)
        CameraRawApproximation.ciContext.render(
            output, toBitmap: &pixel, rowBytes: 16,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBAf, colorSpace: CameraRawApproximation.workingColorSpace
        )
        return SIMD3<Float>(pixel[0], pixel[1], pixel[2])
    }

    private var exposureSectionHeader: some View {
        HStack(spacing: 6) {
            Text("Exposure")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .onTapGesture(count: 2) {
                    if hasExposureAdjustments { resetExposureAdjustments() }
                }
            Spacer()
            Button {
                sectionMutes.toggle(.exposure)
                renderPreview()
            } label: {
                Image(systemName: sectionMutes.isMuted(.exposure) ? "eye.slash" : "eye")
                    .font(.system(size: 11))
                    .foregroundStyle(sectionMutes.isMuted(.exposure) ? .orange : .secondary)
            }
            .buttonStyle(.plain)
            .help(sectionMutes.isMuted(.exposure) ? "Show exposure adjustments" : "Hide exposure adjustments")
            Button {
                resetExposureAdjustments()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!hasExposureAdjustments)
            .help("Reset exposure")
            Text("HDR")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isHDREnabled ? Color.orange : Color.secondary.opacity(0.5))
                .underline(isHoveringHDR)
                .onHover { hovering in
                    isHoveringHDR = hovering
                }
                .onTapGesture {
                    guard canEditSingleImage else { return }
                    hdrToggleBinding.wrappedValue.toggle()
                }
                .help("Toggle HDR mode (\u{2318}H)")
        }
        .padding(.top, 2)
    }

    // MARK: - Mask UI

    /// The editing layer chain shown as a horizontal strip of cards — input (leftmost) to
    /// output (rightmost). Each card is a muted thumbnail with a type icon; cards select on
    /// tap, drag to reorder (the global node included), and expose mute/invert/delete via a
    /// context menu and the action row below.
    private var maskSelectorBar: some View {
        let order = resolvedLayerOrder
        return VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(order, id: \.self) { ref in
                        layerCard(ref)
                    }
                    addLayerButton
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 1)
            }
            if let id = selectedMaskID {
                maskActionRow(id)
            } else if let id = selectedWatermarkID {
                watermarkActionRow(id)
            }
        }
    }

    /// Whether the currently-selected layer is a freeform brush mask.
    private var selectedMaskIsBrush: Bool {
        guard let id = selectedMaskID else { return false }
        return metadataViewModel.editingMetadata.cameraRaw?.localAdjustments?
            .first(where: { $0.id == id })?.brush != nil
    }

    /// Whether the selected mask is a persisted Vision subject/object matte.
    private var selectedMaskIsAI: Bool {
        guard let id = selectedMaskID else { return false }
        return metadataViewModel.editingMetadata.cameraRaw?.localAdjustments?
            .first(where: { $0.id == id })?.aiMask != nil
    }

    /// Secondary Global layers share the adjustment payload with masks, but cover the complete
    /// frame and therefore have no geometry toolbar, outline, invert, or matte affordance.
    private var selectedMaskIsFullFrame: Bool {
        guard let id = selectedMaskID else { return false }
        return metadataViewModel.editingMetadata.cameraRaw?.localAdjustments?
            .first(where: { $0.id == id })?.isFullFrame == true
    }

    private func aiMaskToolbar(id: UUID?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let id {
                    maskMattePreviewIcon(systemName: LayerKind.aiMask.systemImage, maskID: id)
                } else {
                    Image(systemName: LayerKind.aiMask.systemImage)
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                Text("AI Mask").font(.system(size: 11, weight: .semibold))
                Spacer()
                Button(isSelectingAIMask ? "Cancel" : "Select Again") {
                    if isSelectingAIMask {
                        cancelAIMaskSelection()
                    } else {
                        startAIMaskSelection(replacing: id)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Picker("Target", selection: aiMaskTargetBinding(replacing: id)) {
                ForEach(AIMaskTarget.selectableCases, id: \.self) { target in
                    Text(target.title).tag(target)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isGeneratingAIMask)

            if let id,
               let index = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments?
                .firstIndex(where: { $0.id == id }),
               let aiMask = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments?[index].aiMask {
                sliderRow(
                    "Black point",
                    value: aiMaskBlackPointBinding(index),
                    range: 0...100,
                    step: 1,
                    formatter: { "\(Int($0.rounded()))%" },
                    settingsMutator: { settings, value in
                        setAIMaskBlackPoint(value, index: index, settings: &settings)
                    },
                    onReset: {
                        aiMaskBlackPointBinding(index).wrappedValue = 0
                    }
                )

                sliderRow(
                    "White point",
                    value: aiMaskWhitePointBinding(index),
                    range: 0...100,
                    step: 1,
                    formatter: { "\(Int($0.rounded()))%" },
                    settingsMutator: { settings, value in
                        setAIMaskWhitePoint(value, index: index, settings: &settings)
                    },
                    onReset: {
                        aiMaskWhitePointBinding(index).wrappedValue = 100
                    },
                    showReset: aiMask.resolvedWhitePoint < 0.999999
                )

                sliderRow(
                    "Blur",
                    value: aiMaskBlurBinding(index),
                    range: 0...2,
                    step: 0.05,
                    formatter: { String(format: "%.2f%%", $0) },
                    settingsMutator: { settings, value in
                        setAIMaskBlur(value, index: index, settings: &settings)
                    },
                    onReset: {
                        aiMaskBlurBinding(index).wrappedValue = 0
                    }
                )
            }

            Text(aiMaskTarget == .automatic
                 ? "Auto tries the person model first, then the foreground-object model."
                 : aiMaskTarget == .face
                    ? "Face uses Vision face detection to isolate the clicked face."
                    : aiMaskTarget == .person
                        ? "Person uses Vision's dedicated person-instance model."
                        : "Object uses Vision's general foreground-instance model.")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Changing the target on an existing matte immediately enters Select Again mode, because
    /// the model choice only has meaning when Vision is given a new click to regenerate pixels.
    private func aiMaskTargetBinding(replacing id: UUID?) -> Binding<AIMaskTarget> {
        Binding(
            get: { aiMaskTarget },
            set: { target in
                aiMaskTarget = target
                if !isSelectingAIMask {
                    startAIMaskSelection(replacing: id)
                }
            }
        )
    }

    private func aiMaskBlackPointBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: {
                guard let masks = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments,
                      masks.indices.contains(index) else { return 0 }
                return (masks[index].aiMask?.resolvedBlackPoint ?? 0) * 100
            },
            set: { value in
                updateCameraRaw { settings in
                    setAIMaskBlackPoint(value, index: index, settings: &settings)
                }
            }
        )
    }

    private func aiMaskWhitePointBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: {
                guard let masks = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments,
                      masks.indices.contains(index) else { return 100 }
                return (masks[index].aiMask?.resolvedWhitePoint ?? 1) * 100
            },
            set: { value in
                updateCameraRaw { settings in
                    setAIMaskWhitePoint(value, index: index, settings: &settings)
                }
            }
        )
    }

    private func aiMaskBlurBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: {
                guard let masks = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments,
                      masks.indices.contains(index) else { return 0 }
                return (masks[index].aiMask?.resolvedBlurRadius ?? 0) * 100
            },
            set: { value in
                updateCameraRaw { settings in
                    setAIMaskBlur(value, index: index, settings: &settings)
                }
            }
        )
    }

    private func setAIMaskBlackPoint(
        _ value: Double, index: Int, settings: inout CameraRawSettings
    ) {
        guard let masks = settings.localAdjustments, index < masks.count,
              var aiMask = masks[index].aiMask else { return }
        let maximum = max(0, aiMask.resolvedWhitePoint - 0.01)
        let normalized = min(max(value / 100, 0), maximum)
        aiMask.blackPoint = normalized <= 0.000001 ? nil : normalized
        settings.localAdjustments?[index].aiMask = aiMask
    }

    private func setAIMaskWhitePoint(
        _ value: Double, index: Int, settings: inout CameraRawSettings
    ) {
        guard let masks = settings.localAdjustments, index < masks.count,
              var aiMask = masks[index].aiMask else { return }
        let minimum = min(1, aiMask.resolvedBlackPoint + 0.01)
        let normalized = min(max(value / 100, minimum), 1)
        aiMask.whitePoint = normalized >= 0.999999 ? nil : normalized
        settings.localAdjustments?[index].aiMask = aiMask
    }

    private func setAIMaskBlur(
        _ value: Double, index: Int, settings: inout CameraRawSettings
    ) {
        guard let masks = settings.localAdjustments, index < masks.count,
              var aiMask = masks[index].aiMask else { return }
        let normalized = min(max(value / 100, 0), 0.02)
        aiMask.blurRadius = normalized <= 0.000001 ? nil : normalized
        settings.localAdjustments?[index].aiMask = aiMask
    }

    /// Brush-settings toolbar, shown while the brush tool is active or a brush mask is selected.
    /// The "Paint" toggle mirrors the bare-`B` shortcut so the tool is discoverable without it;
    /// the sliders describe what's about to be painted (already-painted strokes keep their own).
    private var brushToolbar: some View {
        @Bindable var maskInteraction = maskInteraction

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if selectedMaskIsBrush, let id = selectedMaskID {
                    maskMattePreviewIcon(systemName: "paintbrush.pointed", maskID: id)
                } else {
                    Image(systemName: "paintbrush.pointed")
                        .frame(width: 20, height: 20)
                }
                Text("Brush").font(.system(size: 11, weight: .semibold))
                Spacer()
                Button {
                    maskInteraction.toggleBrushPainting()
                    if isBrushPainting { isPickingWhiteBalance = false }
                    syncMaskOverlayTarget()
                } label: {
                    Text(isBrushPainting ? "Painting" : "Paint")
                        .frame(minWidth: 54)
                }
                .buttonStyle(.borderedProminent)
                .tint(isBrushPainting ? .accentColor : .gray)
                .controlSize(.small)
                .help("Toggle the paint tool (shortcut: B)")
            }
            Picker("", selection: $maskInteraction.brushErase) {
                Text("Add").tag(false)
                Text("Erase").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            brushSlider("Size", value: $maskInteraction.brushRadius, range: 0.005...0.20)
            brushSlider("Hardness", value: $maskInteraction.brushHardness, range: 0...1)
            brushSlider("Flow", value: $maskInteraction.brushFlow, range: 0.05...1)
            Text(isBrushPainting ? "Drag on the image to paint. Press B to exit."
                                 : "Turn on Paint (or press B), then drag on the image.")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Shared controls for the ACR-compatible ellipse and Photo Agent's rounded-rectangle
    /// extension. At 100% corners the two renderings are identical; lowering the value keeps
    /// the CircularGradient fallback for ACR while Photo Agent renders the extended shape.
    private func analyticMaskToolbar(index: Int, id: UUID) -> some View {
        let geometry = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments?[index].geometry
            ?? EllipseMaskGeometry()
        let kind: LayerKind = geometry.isStandardEllipse ? .ellipseMask : .rectangleMask
        let title = geometry.isStandardEllipse ? "Ellipse Mask" : "Rectangle Mask"

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                maskMattePreviewIcon(systemName: kind.systemImage, maskID: id)
                Text(title).font(.system(size: 11, weight: .semibold))
                Spacer()
            }

            sliderRow(
                "Corner radius",
                value: maskCornerRadiusBinding(index),
                range: 0...100,
                step: 1,
                formatter: { "\(Int($0.rounded()))%" },
                settingsMutator: { settings, value in
                    let normalized = min(max(value / 100, 0), 1)
                    settings.localAdjustments?[index].geometry.cornerRadius =
                        normalized >= 0.999999 ? nil : normalized
                    // Like the Metal preview, the AppKit outline intentionally reads a
                    // transient geometry while a high-frequency slider drag bypasses the
                    // observed model. Keep both previews on the same live value.
                    dragMaskGeometry = settings.localAdjustments?[index].geometry
                },
                onSliderEditingChanged: { editing in
                    if !editing {
                        // EditSlider commits its final value to the binding before sending
                        // the editing-ended callback, so the model is authoritative again.
                        dragMaskGeometry = nil
                    }
                },
                onReset: {
                    maskCornerRadiusBinding(index).wrappedValue = 100
                }
            )

            sliderRow(
                "Feather",
                value: maskGeometryBinding(index, \.feather),
                range: 0...100,
                step: 1,
                formatter: { "\(Int($0.rounded()))" },
                settingsMutator: { settings, value in
                    settings.localAdjustments?[index].geometry.feather = value.rounded()
                },
                onReset: {
                    maskGeometryBinding(index, \.feather).wrappedValue = 50
                }
            )

            Text("100% is the ACR ellipse; lower values are a Photo Agent extension.")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Shared hover affordance for every mask type. Future mask tools can opt into the same
    /// matte behavior by using this icon rather than owning preview state themselves.
    private func maskMattePreviewIcon(systemName: String, maskID: UUID) -> some View {
        Image(systemName: systemName)
            .foregroundStyle(maskMattePreviewMaskID == maskID ? Color.primary : Color.secondary)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
            .onHover { isHovering in
                setMaskMattePreview(maskID: maskID, visible: isHovering)
            }
            .help("Hover to preview the mask matte")
    }

    private func brushSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10))
                .frame(width: 58, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.0f%%", value.wrappedValue / range.upperBound * 100))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }

    /// Resolved processing order of the current edit (defaults to `[.global]` when there are
    /// no settings yet), driving both the card strip and the render pipeline.
    private var resolvedLayerOrder: [LayerRef] {
        (metadataViewModel.editingMetadata.cameraRaw ?? CameraRawSettings()).resolvedLayerOrder()
    }

    /// UUID of the selected mask, or nil when Global is selected / the mask was deleted.
    private var selectedMaskID: UUID? {
        if case .mask(let id) = selectedLayer,
           metadataViewModel.editingMetadata.cameraRaw?.localAdjustments?.contains(where: { $0.id == id }) == true {
            return id
        }
        return nil
    }

    /// UUID of the selected watermark layer, or nil when a different layer is selected / the
    /// layer was deleted.
    private var selectedWatermarkID: UUID? {
        if case .watermark(let id) = selectedLayer,
           metadataViewModel.editingMetadata.cameraRaw?.watermarkLayers?.contains(where: { $0.id == id }) == true {
            return id
        }
        return nil
    }

    private var addLayerButton: some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            GridRow {
                addLayerTile(kind: .ellipseMask, tint: .blue, help: "Add ellipse mask") {
                    addNewMask()
                }
                addLayerTile(kind: .brushMask, tint: .blue, help: "Add brush mask") {
                    _ = addNewBrushMask()
                    maskInteraction.beginBrushPainting()
                    isPickingWhiteBalance = false
                    syncMaskOverlayTarget()
                }
                addLayerTile(kind: .aiMask, tint: .blue, help: "Select a person or object with AI") {
                    startAIMaskSelection()
                }
            }
            GridRow {
                addGlobalLayerTile()
                addLayerTile(kind: .colorTransform, tint: .green, help: "Add LUT or CST layer") {
                    addNewColorTransformLayer()
                }
                addLayerTile(kind: .watermark, tint: .yellow, help: "Add watermark layer") {
                    addNewWatermarkLayer()
                }
            }
        }
        .frame(width: 86, height: 56)
        .alert("No Watermarks in Library", isPresented: $showWatermarkLibraryEmptyAlert) {
            Button("OK") {}
        } message: {
            Text("Import a PNG watermark first, from Settings \u{2192} Watermarks.")
        }
        .alert(
            "AI Mask",
            isPresented: Binding(
                get: { aiMaskError != nil },
                set: { if !$0 { aiMaskError = nil } }
            )
        ) {
            Button("OK") { aiMaskError = nil }
        } message: {
            Text(aiMaskError ?? "The mask could not be generated.")
        }
        .alert(
            "Color Transform",
            isPresented: Binding(
                get: { colorTransformError != nil },
                set: { if !$0 { colorTransformError = nil } }
            )
        ) {
            Button("OK") { colorTransformError = nil }
        } message: {
            Text(colorTransformError ?? "The color transform could not be loaded.")
        }
        .alert("Rename Layer", isPresented: $isShowingLayerRename) {
            TextField("Layer name", text: $layerNameDraft)
            Button("Cancel", role: .cancel) {
                cancelLayerRename()
            }
            Button("Rename") {
                commitLayerRename()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(layerNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Enter a name for this develop layer.")
        }
        .fileImporter(
            isPresented: $isShowingLUTImporter,
            allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            importColorLUT(result)
        }
    }

    /// Six launchers occupy a compact 3×2 slot. Every launcher uses the same dashed-square
    /// treatment; a quiet background tint groups local, global, and overlay layer types.
    private func addLayerTile(
        kind: LayerKind,
        tint: Color,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(tint.opacity(hoveredAddLayerKind == kind ? 0.22 : 0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [2]))
                        .foregroundStyle(.secondary)
                )
                // The whole frame is the hit area, not just the (stroked) border + icon pixels.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredAddLayerKind = $0 ? kind : nil }
        .help(help)
    }

    private func addGlobalLayerTile() -> some View {
        Button {
            addNewGlobalLayer()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.green.opacity(
                            hoveredAddLayerKind == .secondaryGlobal ? 0.22 : 0.1
                        ))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [2]))
                        .foregroundStyle(.secondary)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredAddLayerKind = $0 ? .secondaryGlobal : nil }
        .help("Add Global adjustment layer")
    }

    @ViewBuilder
    private func layerCard(_ ref: LayerRef) -> some View {
        let mask = maskFor(ref)
        let watermark = watermarkFor(ref)
        let isSelected = ref == selectedLayer
        let muted = mask.map { !$0.enabled } ?? watermark.map { !$0.enabled } ?? false
        let kind: LayerKind = mask?.layerKind ?? watermark?.layerKind ?? .global

        VStack(spacing: 3) {
            ZStack {
                Group {
                    if let img = sourceImage {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(Color.secondary.opacity(0.25))
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .saturation(0)
                .brightness(hoveredLayer == ref ? 0.18 : -0.05)
                .opacity(muted ? 0.3 : 0.6)

                Image(systemName: kind.systemImage)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 1.5)
            }
            .frame(width: 56, height: 56)
            .overlay(alignment: .topLeading) {
                if mask?.inverted == true {
                    Image(systemName: "circle.righthalf.filled")
                        .font(.system(size: 9))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.7), radius: 1)
                        .padding(3)
                }
            }
            .overlay(alignment: .topTrailing) {
                if muted {
                    Image(systemName: "eye.slash.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.red)
                        .shadow(color: .black.opacity(0.7), radius: 1)
                        .padding(3)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(dropTargetLayer == ref && draggingLayer != ref ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 2)
            )

            Text(layerName(ref, mask: mask))
                .font(.system(size: 9))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .lineLimit(1)
                .frame(width: 60)
                .onTapGesture(count: 2) {
                    beginLayerRename(ref)
                }
        }
        .contentShape(Rectangle())
        .opacity(draggingLayer == ref ? 0.4 : 1)
        .onHover { hoveredLayer = $0 ? ref : nil }
        .onTapGesture { selectedLayer = ref }
        .onDrag {
            draggingLayer = ref
            return NSItemProvider(object: layerRefString(ref) as NSString)
        }
        .onDrop(
            of: [.text],
            isTargeted: Binding(
                get: { dropTargetLayer == ref },
                set: { dropTargetLayer = $0 ? ref : (dropTargetLayer == ref ? nil : dropTargetLayer) }
            )
        ) { _ in
            defer { draggingLayer = nil; dropTargetLayer = nil }
            guard let dragged = draggingLayer else { return false }
            dropLayer(dragged, onto: ref)
            return true
        }
        .contextMenu {
            if let mask {
                Button("Rename…") { beginLayerRename(ref) }
                Button(mask.enabled ? "Mute" : "Enable") { toggleMaskEnabled(mask.id) }
                if !mask.isFullFrame {
                    Button(mask.inverted ? "Normal (inside mask)" : "Invert (outside mask)") {
                        toggleMaskInverted(mask.id)
                    }
                }
                Divider()
                Button("Delete", role: .destructive) {
                    selectedLayer = ref
                    deleteSelectedMask()
                }
            } else if let watermark {
                Button("Rename…") { beginLayerRename(ref) }
                Button(watermark.enabled ? "Mute" : "Enable") { toggleWatermarkEnabled(watermark.id) }
                Divider()
                Button("Delete", role: .destructive) {
                    selectedLayer = ref
                    deleteSelectedWatermark()
                }
            }
        }
        .help(layerName(ref, mask: mask))
    }

    /// Mute / invert / delete controls for the selected mask, shown beneath the strip.
    @ViewBuilder
    private func maskActionRow(_ id: UUID) -> some View {
        if let mask = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments?.first(where: { $0.id == id }) {
            HStack(spacing: 10) {
                if !mask.isFullFrame {
                    Button {
                        toggleMaskInverted(id)
                    } label: {
                        Image(systemName: "circle.dashed.inset.filled")
                            .font(.system(size: 11))
                            .foregroundStyle(mask.inverted ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(mask.inverted ? "Inverted: adjustments apply outside the mask" : "Normal: adjustments apply inside the mask")
                }

                Button {
                    toggleMaskEnabled(id)
                } label: {
                    Image(systemName: mask.enabled ? "eye" : "eye.slash")
                        .font(.system(size: 11))
                        .foregroundStyle(mask.enabled ? Color.secondary : Color.red)
                }
                .buttonStyle(.plain)
                .help(mask.enabled ? "Mute mask effect" : "Enable mask effect")

                if !mask.isFullFrame {
                    Button {
                        showsMaskOutlines.toggle()
                        if !showsMaskOutlines {
                            metalPipeline?.updateOverlayParams(geometry: nil, visible: false)
                        }
                    } label: {
                        Image(systemName: "circle.dashed")
                            .font(.system(size: 11))
                            .foregroundStyle(showsMaskOutlines ? Color.secondary : Color.red)
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.plain)
                    .help(showsMaskOutlines ? "Hide all mask outlines" : "Show mask outlines")
                }

                Spacer()

                Button {
                    deleteSelectedMask()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete mask")
            }
            .padding(.horizontal, 2)
        }
    }

    private func maskFor(_ ref: LayerRef) -> MaskAdjustment? {
        guard case .mask(let id) = ref else { return nil }
        return metadataViewModel.editingMetadata.cameraRaw?.localAdjustments?.first { $0.id == id }
    }

    private func watermarkFor(_ ref: LayerRef) -> WatermarkLayer? {
        guard case .watermark(let id) = ref else { return nil }
        return metadataViewModel.editingMetadata.cameraRaw?.watermarkLayers?.first { $0.id == id }
    }

    private func layerName(_ ref: LayerRef, mask: MaskAdjustment?) -> String {
        switch ref {
        case .global:    return "Global"
        case .mask:      return mask?.name ?? "Mask"
        case .watermark: return watermarkFor(ref)?.name ?? "Watermark"
        }
    }

    private func beginLayerRename(_ ref: LayerRef) {
        guard ref != .global else { return }
        guard maskFor(ref) != nil || watermarkFor(ref) != nil else { return }
        selectedLayer = ref
        layerBeingRenamed = ref
        layerNameDraft = layerName(ref, mask: maskFor(ref))
        isShowingLayerRename = true
    }

    private func cancelLayerRename() {
        isShowingLayerRename = false
        layerBeingRenamed = nil
        layerNameDraft = ""
    }

    private func commitLayerRename() {
        let trimmedName = layerNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ref = layerBeingRenamed, !trimmedName.isEmpty else {
            cancelLayerRename()
            return
        }
        let currentName = layerName(ref, mask: maskFor(ref))
        guard currentName != trimmedName else {
            cancelLayerRename()
            return
        }

        updateCameraRaw { cameraRaw in
            switch ref {
            case .global:
                break
            case .mask(let id):
                guard let index = cameraRaw.localAdjustments?
                    .firstIndex(where: { $0.id == id }) else { return }
                cameraRaw.localAdjustments?[index].name = trimmedName
            case .watermark(let id):
                guard let index = cameraRaw.watermarkLayers?
                    .firstIndex(where: { $0.id == id }) else { return }
                cameraRaw.watermarkLayers?[index].name = trimmedName
            }
        }
        cancelLayerRename()
        commitEditAdjustments()
    }

    private func layerRefString(_ ref: LayerRef) -> String {
        ref.token
    }

    /// Reorders the layer chain so `dragged` takes `target`'s slot. A single `updateCameraRaw`
    /// keeps it to one undo step.
    private func dropLayer(_ dragged: LayerRef, onto target: LayerRef) {
        guard dragged != target else { return }
        updateCameraRaw { cameraRaw in
            var order = cameraRaw.resolvedLayerOrder()
            guard let from = order.firstIndex(of: dragged) else { return }
            order.remove(at: from)
            guard let to = order.firstIndex(of: target) else { return }
            order.insert(dragged, at: to)
            cameraRaw.layerOrder = order
        }
        commitEditAdjustments()
    }

    private func toggleMaskInverted(_ id: UUID) {
        updateCameraRaw { cameraRaw in
            guard let i = cameraRaw.localAdjustments?.firstIndex(where: { $0.id == id }) else { return }
            cameraRaw.localAdjustments?[i].inverted.toggle()
        }
        commitEditAdjustments()
    }

    private func toggleMaskEnabled(_ id: UUID) {
        updateCameraRaw { cameraRaw in
            guard let i = cameraRaw.localAdjustments?.firstIndex(where: { $0.id == id }) else { return }
            cameraRaw.localAdjustments?[i].enabled.toggle()
        }
        commitEditAdjustments()
    }

    @ViewBuilder
    private var colorTransformLayerControls: some View {
        if let idx = selectedColorTransformIndex,
           let masks = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments,
           masks.indices.contains(idx),
           let transform = masks[idx].colorTransform {
            Text("Color Transform")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Divider()

            Picker("Mode", selection: colorTransformModeBinding(idx)) {
                ForEach(ColorTransformMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if transform.mode == .lut {
                HStack(spacing: 8) {
                    Image(systemName: "cube.transparent")
                        .foregroundStyle(transform.hasLUT ? Color.accentColor : Color.secondary)
                    Text(transform.lutName ?? "No LUT selected")
                        .font(.system(size: 10))
                        .foregroundStyle(transform.hasLUT ? Color.primary : Color.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button(transform.hasLUT ? "Replace…" : "Choose…") {
                        beginColorLUTImport(for: masks[idx].id)
                    }
                    .controlSize(.small)
                }
                Text("IRIDAS/Resolve 3D .cube files from 2³ through 65³ are supported.")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            } else {
                Picker("Input", selection: colorTransformSpaceBinding(idx, \.inputSpace)) {
                    ForEach(ColorTransformSpace.allCases, id: \.self) { space in
                        Text(space.title).tag(space)
                    }
                }
                Picker("Output", selection: colorTransformSpaceBinding(idx, \.outputSpace)) {
                    ForEach(ColorTransformSpace.allCases, id: \.self) { space in
                        Text(space.title).tag(space)
                    }
                }
                HStack {
                    Spacer()
                    Button {
                        updateCameraRaw { cameraRaw in
                            guard let transform = cameraRaw.localAdjustments?[idx].colorTransform
                            else { return }
                            cameraRaw.localAdjustments?[idx].colorTransform?.inputSpace =
                                transform.outputSpace
                            cameraRaw.localAdjustments?[idx].colorTransform?.outputSpace =
                                transform.inputSpace
                        }
                        commitEditAdjustments()
                    } label: {
                        Label("Swap", systemImage: "arrow.up.arrow.down")
                    }
                    .controlSize(.small)
                }
                Text("CST currently operates between linear RGB primaries inside the editor’s linear pipeline.")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            sliderRow(
                "Opacity",
                value: maskAmountBinding(idx),
                range: 0...100,
                step: 1,
                formatter: { "\(Int($0.rounded()))%" },
                settingsMutator: { settings, value in
                    settings.localAdjustments?[idx].amount = min(max(value / 100, 0), 1)
                },
                onReset: { maskAmountBinding(idx).wrappedValue = 100 }
            )
        }
    }

    private func colorTransformModeBinding(_ index: Int) -> Binding<ColorTransformMode> {
        Binding(
            get: {
                metadataViewModel.editingMetadata.cameraRaw?.localAdjustments?[index]
                    .colorTransform?.mode ?? .lut
            },
            set: { mode in
                updateCameraRaw { cameraRaw in
                    cameraRaw.localAdjustments?[index].colorTransform?.mode = mode
                }
                commitEditAdjustments()
            }
        )
    }

    private func colorTransformSpaceBinding(
        _ index: Int,
        _ keyPath: WritableKeyPath<ColorTransformSettings, ColorTransformSpace>
    ) -> Binding<ColorTransformSpace> {
        Binding(
            get: {
                guard let transform = metadataViewModel.editingMetadata.cameraRaw?
                    .localAdjustments?[index].colorTransform else { return .linearSRGB }
                return transform[keyPath: keyPath]
            },
            set: { space in
                updateCameraRaw { cameraRaw in
                    guard var transform = cameraRaw.localAdjustments?[index].colorTransform
                    else { return }
                    transform[keyPath: keyPath] = space
                    cameraRaw.localAdjustments?[index].colorTransform = transform
                }
                commitEditAdjustments()
            }
        )
    }

    @ViewBuilder
    private var maskAdjustmentSliders: some View {
        if let idx = selectedMaskIndex,
           let masks = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments,
           idx < masks.count {

            Text(masks[idx].isFullFrame ? "Global Adjustments" : "Mask Adjustments")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Divider()

            // Per-mask opacity (the mask's overall strength). Only mask layers have this — the
            // Global layer is always fully applied.
            sliderRow(
                "Opacity",
                value: maskAmountBinding(idx),
                range: 0...100,
                step: 1,
                formatter: { "\(Int($0.rounded()))%" },
                settingsMutator: { settings, value in
                    settings.localAdjustments?[idx].amount = min(max(value / 100, 0), 1)
                },
                onReset: { maskAmountBinding(idx).wrappedValue = 100 }
            )

            sliderRow(
                "Temperature",
                value: maskDoubleBinding(idx, \.temperature),
                range: -100...100,
                step: 1,
                gradientColors: [.blue, .yellow],
                formatter: signedIntString,
                settingsMutator: { settings, value in
                    let rounded = value.rounded()
                    settings.localAdjustments?[idx].temperature = rounded == 0 ? nil : rounded
                },
                onReset: {
                    maskDoubleBinding(idx, \.temperature).wrappedValue = 0
                }
            )
            sliderRow(
                "Tint",
                value: maskDoubleBinding(idx, \.tint),
                range: -100...100,
                step: 1,
                gradientColors: [.green, .pink],
                formatter: signedIntString,
                settingsMutator: { settings, value in
                    let rounded = value.rounded()
                    settings.localAdjustments?[idx].tint = rounded == 0 ? nil : rounded
                },
                onReset: {
                    maskDoubleBinding(idx, \.tint).wrappedValue = 0
                }
            )

            sliderRow(
                "Exposure",
                value: maskDoubleBinding(idx, \.exposure),
                range: -4...4,
                step: 0.01,
                formatter: { signedDoubleString($0, precision: 2) },
                settingsMutator: { settings, value in
                    settings.localAdjustments?[idx].exposure = abs(value) < 0.001 ? nil : (value * 100).rounded() / 100
                },
                onReset: {
                    maskDoubleBinding(idx, \.exposure).wrappedValue = 0
                }
            )
            sliderRow(
                "Contrast",
                value: maskIntBinding(idx, \.contrast),
                range: -100...100,
                step: 1,
                formatter: signedIntString,
                visibility: .contrast,
                settingsMutator: { settings, value in
                    settings.localAdjustments?[idx].contrast = Int(value.rounded()) == 0 ? nil : Int(value.rounded())
                },
                onReset: {
                    maskIntBinding(idx, \.contrast).wrappedValue = 0
                }
            )
            sliderRow(
                "Highlights",
                value: maskIntBinding(idx, \.highlights),
                range: -100...100,
                step: 1,
                formatter: signedIntString,
                visibility: .highlights,
                settingsMutator: { settings, value in
                    settings.localAdjustments?[idx].highlights = Int(value.rounded()) == 0 ? nil : Int(value.rounded())
                },
                onReset: {
                    maskIntBinding(idx, \.highlights).wrappedValue = 0
                }
            )
            sliderRow(
                "Shadows",
                value: maskIntBinding(idx, \.shadows),
                range: -100...100,
                step: 1,
                formatter: signedIntString,
                visibility: .shadows,
                settingsMutator: { settings, value in
                    settings.localAdjustments?[idx].shadows = Int(value.rounded()) == 0 ? nil : Int(value.rounded())
                },
                onReset: {
                    maskIntBinding(idx, \.shadows).wrappedValue = 0
                }
            )
            sliderRow(
                "Whites",
                value: maskIntBinding(idx, \.whites),
                range: -100...100,
                step: 1,
                formatter: signedIntString,
                visibility: .whites,
                settingsMutator: { settings, value in
                    settings.localAdjustments?[idx].whites = Int(value.rounded()) == 0 ? nil : Int(value.rounded())
                },
                onReset: {
                    maskIntBinding(idx, \.whites).wrappedValue = 0
                }
            )
            sliderRow(
                "Blacks",
                value: maskIntBinding(idx, \.blacks),
                range: -100...100,
                step: 1,
                formatter: signedIntString,
                visibility: .blacks,
                settingsMutator: { settings, value in
                    settings.localAdjustments?[idx].blacks = Int(value.rounded()) == 0 ? nil : Int(value.rounded())
                },
                onReset: {
                    maskIntBinding(idx, \.blacks).wrappedValue = 0
                }
            )
            sliderRow(
                "Saturation",
                value: maskIntBinding(idx, \.saturation),
                range: -100...100,
                step: 1,
                gradientColors: [.gray, .red],
                formatter: signedIntString,
                visibility: .saturation,
                settingsMutator: { settings, value in
                    settings.localAdjustments?[idx].saturation = Int(value.rounded()) == 0 ? nil : Int(value.rounded())
                },
                onReset: {
                    maskIntBinding(idx, \.saturation).wrappedValue = 0
                }
            )
            sliderRow(
                "Vibrance",
                value: maskIntBinding(idx, \.vibrance),
                range: -100...100,
                step: 1,
                gradientColors: [.gray, .orange],
                formatter: signedIntString,
                visibility: .vibrance,
                settingsMutator: { settings, value in
                    settings.localAdjustments?[idx].vibrance = Int(value.rounded()) == 0 ? nil : Int(value.rounded())
                },
                onReset: {
                    maskIntBinding(idx, \.vibrance).wrappedValue = 0
                }
            )
            if settingsViewModel.isDevelopSliderGroupVisible(.privacy) {
                // ── Anonymizer ──
                HStack(spacing: 6) {
                    Text("Anonymizer")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Toggle("Enable anonymizer", isOn: maskAnonymizerEnabledBinding(idx))
                        .labelsHidden()
                        .controlSize(.mini)
                        .help("Enable anonymizer at strength 30")
                    Spacer()
                }
                .padding(.top, 2)
                Divider()

                sliderRow(
                    "Anonymizer",
                    value: maskAnonymizerAmountBinding(idx),
                    range: 0...100,
                    step: 1,
                    formatter: { "\(Int($0.rounded()))" },
                    visibility: .anonymizer,
                    settingsMutator: { settings, value in
                        let clamped = min(max(value.rounded(), 0), 100)
                        if clamped <= 0 {
                            settings.localAdjustments?[idx].anonymizer?.amount = nil
                            if settings.localAdjustments?[idx].anonymizer?.isEmpty == true {
                                settings.localAdjustments?[idx].anonymizer = nil
                            }
                        } else {
                            if settings.localAdjustments?[idx].anonymizer == nil {
                                settings.localAdjustments?[idx].anonymizer = AnonymizerSettings()
                            }
                            settings.localAdjustments?[idx].anonymizer?.amount = clamped
                        }
                    },
                    onReset: {
                        maskAnonymizerAmountBinding(idx).wrappedValue = 0
                    }
                )
                .disabled(
                    !maskAnonymizerEnabledBinding(idx).wrappedValue
                        || maskAnonymizerBlackOutBinding(idx).wrappedValue
                )

                Toggle("Black out", isOn: maskAnonymizerBlackOutBinding(idx))
                    .toggleStyle(.checkbox)
                    .disabled(!maskAnonymizerEnabledBinding(idx).wrappedValue)
                    .help("Fully redact this mask instead of the mosaic effect")
            }
        }
    }

    /// Watermark layer's control panel: which library image, size (px/% × width/height),
    /// margin (px/%), and opacity. No color/tonal controls (a watermark layer doesn't have
    /// any) and no invert (not a meaningful concept here).
    @ViewBuilder
    private var watermarkLayerControls: some View {
        if let idx = selectedWatermarkIndex,
           let layers = metadataViewModel.editingMetadata.cameraRaw?.watermarkLayers,
           idx < layers.count {

            Text("Watermark")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Divider()

            let library = WatermarkStore.shared.allAssets()
            if library.isEmpty {
                Label("No watermarks in your library yet — import a PNG from Settings \u{2192} Watermarks.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Image", selection: watermarkAssetIDBinding(idx)) {
                    ForEach(library) { asset in
                        Text(asset.name).tag(Optional(asset.id))
                    }
                }
                .labelsHidden()
            }

            Text("Size")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            Divider()

            HStack(spacing: 8) {
                Picker("", selection: watermarkSizeUnitBinding(idx)) {
                    Text("px").tag(WatermarkSizeUnit.pixel)
                    Text("%").tag(WatermarkSizeUnit.percent)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 70)

                Picker("", selection: watermarkSizeDimensionBinding(idx)) {
                    Text("Width").tag(WatermarkDimension.width)
                    Text("Height").tag(WatermarkDimension.height)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            let assetAspectValue = assetAspect(forWatermarkAssetID: layers[idx].libraryAssetID)
            let sizeIsPercent = watermarkSizeUnitBinding(idx).wrappedValue == .percent
            sliderRow(
                "Size",
                value: watermarkSizeValueBinding(idx),
                range: sizeIsPercent ? 1...100 : 8...4000,
                step: 1,
                formatter: { sizeIsPercent ? "\(Int($0.rounded()))%" : "\(Int($0.rounded()))px" },
                settingsMutator: { settings, value in
                    settings.watermarkLayers?[idx].geometry.sizeValue = value
                    // Re-clamp live too, so the position visibly moves inward while dragging
                    // the size slider, not just once the drag ends.
                    if let g = settings.watermarkLayers?[idx].geometry {
                        let reclamped = watermarkGeometryClampingOwnPosition(g, assetAspect: assetAspectValue)
                        settings.watermarkLayers?[idx].geometry = reclamped
                        // The overlay (footprint outline + dashed margin line) reads from
                        // SwiftUI state, which this live-drag path otherwise bypasses entirely
                        // (by design, to avoid a full body re-evaluation per mouse pixel) — feed
                        // it through the same override the position-handle drag already uses,
                        // so the overlay tracks the live resize instead of only updating on release.
                        dragWatermarkGeometry = reclamped
                    }
                },
                onReset: {
                    watermarkSizeValueBinding(idx).wrappedValue = 20
                }
            )

            Text("Margin")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            Divider()
            Text("Restricts how close to the image edge the watermark can be dragged.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("", selection: watermarkMarginUnitBinding(idx)) {
                Text("px").tag(WatermarkMarginUnit.pixel)
                Text("%").tag(WatermarkMarginUnit.percent)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 70)

            let marginIsPercent = watermarkMarginUnitBinding(idx).wrappedValue == .percent
            sliderRow(
                "Margin",
                value: watermarkMarginValueBinding(idx),
                range: marginIsPercent ? 0...45 : 0...2000,
                step: 1,
                formatter: { marginIsPercent ? "\(Int($0.rounded()))%" : "\(Int($0.rounded()))px" },
                settingsMutator: { settings, value in
                    settings.watermarkLayers?[idx].geometry.marginValue = value
                    // Re-clamp live too, so the position visibly moves inward while dragging
                    // the margin slider, not just once the drag ends.
                    if let g = settings.watermarkLayers?[idx].geometry {
                        let reclamped = watermarkGeometryClampingOwnPosition(g, assetAspect: assetAspectValue)
                        settings.watermarkLayers?[idx].geometry = reclamped
                        // Feed the overlay (dashed margin line + footprint outline) through the
                        // same live-override state the position-handle drag uses — see the Size
                        // slider's identical comment above.
                        dragWatermarkGeometry = reclamped
                    }
                },
                onReset: {
                    watermarkMarginValueBinding(idx).wrappedValue = 10
                }
            )

            Text("Opacity")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            Divider()

            sliderRow(
                "Opacity",
                value: watermarkOpacityBinding(idx),
                range: 0...100,
                step: 1,
                formatter: { "\(Int($0.rounded()))%" },
                settingsMutator: { settings, value in
                    settings.watermarkLayers?[idx].opacity = min(max(value / 100, 0), 1)
                },
                onReset: {
                    watermarkOpacityBinding(idx).wrappedValue = 100
                }
            )
        }
    }

    private func maskGeometryBinding(_ maskIndex: Int, _ keyPath: WritableKeyPath<EllipseMaskGeometry, Double>) -> Binding<Double> {
        Binding(
            get: {
                guard let masks = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments,
                      maskIndex < masks.count else { return 50 }
                return masks[maskIndex].geometry[keyPath: keyPath]
            },
            set: { newValue in
                updateCameraRaw { cameraRaw in
                    guard let masks = cameraRaw.localAdjustments, maskIndex < masks.count else { return }
                    cameraRaw.localAdjustments?[maskIndex].geometry[keyPath: keyPath] = newValue
                }
            }
        )
    }

    /// UI uses 0...100 while the persisted Photo Agent extension is normalized 0...1.
    /// Writing the ellipse endpoint as nil avoids adding custom metadata to untouched ACR masks.
    private func maskCornerRadiusBinding(_ maskIndex: Int) -> Binding<Double> {
        Binding(
            get: {
                guard let masks = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments,
                      maskIndex < masks.count else { return 100 }
                return masks[maskIndex].geometry.normalizedCornerRadius * 100
            },
            set: { newValue in
                updateCameraRaw { cameraRaw in
                    guard let masks = cameraRaw.localAdjustments, maskIndex < masks.count else { return }
                    let normalized = min(max(newValue / 100, 0), 1)
                    cameraRaw.localAdjustments?[maskIndex].geometry.cornerRadius =
                        normalized >= 0.999999 ? nil : normalized
                }
            }
        )
    }

    /// Live array index of the selected mask in `localAdjustments`, or nil when Global is
    /// selected (or the selected mask was deleted). Resolved by UUID every access so it stays
    /// correct after reordering — callers index `localAdjustments` with the current value.
    private var selectedMaskIndex: Int? {
        guard case .mask(let id) = selectedLayer else { return nil }
        return metadataViewModel.editingMetadata.cameraRaw?.localAdjustments?.firstIndex { $0.id == id }
    }

    private var selectedColorTransformIndex: Int? {
        guard let index = selectedMaskIndex,
              metadataViewModel.editingMetadata.cameraRaw?.localAdjustments?[index]
                .colorTransform != nil else { return nil }
        return index
    }

    /// Live array index of the selected watermark layer in `watermarkLayers`, mirroring
    /// `selectedMaskIndex`.
    private var selectedWatermarkIndex: Int? {
        guard case .watermark(let id) = selectedLayer else { return nil }
        return metadataViewModel.editingMetadata.cameraRaw?.watermarkLayers?.firstIndex { $0.id == id }
    }

    // MARK: - Watermark bindings

    /// Re-clamps a (sensor-frame) watermark geometry's position into the margin-inset safe
    /// area implied by its OWN (possibly just-changed) size/margin fields — used whenever
    /// size or margin changes so the watermark visibly moves inward immediately instead of
    /// only correcting the next time the position handle is dragged. No-op if the display
    /// image size isn't known yet.
    private func watermarkGeometryClampingOwnPosition(_ geometry: WatermarkGeometry, assetAspect: Double) -> WatermarkGeometry {
        guard let size = currentImageSize, size.width > 0, size.height > 0 else { return geometry }
        let cropFrame = metadataViewModel.editingMetadata.cameraRaw?.crop?.isEffectiveCrop == true
        let referenceSize = cropFrame ? watermarkCropImageSize(from: size) : size
        let display = watermarkGeometryForDisplay(geometry, includeStraighten: !cropFrame)
            .clamped(assetAspect: assetAspect, imageWidth: referenceSize.width, imageHeight: referenceSize.height)
        return watermarkGeometryForSensor(display, includeStraighten: !cropFrame)
    }

    /// Applies `mutate` to the selected watermark layer's geometry, then re-clamps its
    /// position — the shared commit path for every size/margin/unit control, so adjusting any
    /// of them keeps the watermark visibly in bounds rather than deferring the correction to
    /// the next drag.
    private func updateWatermarkGeometry(_ index: Int, _ mutate: (inout WatermarkGeometry) -> Void) {
        guard let layers = metadataViewModel.editingMetadata.cameraRaw?.watermarkLayers, index < layers.count else { return }
        let assetAspectValue = assetAspect(forWatermarkAssetID: layers[index].libraryAssetID)
        updateCameraRaw { cameraRaw in
            guard let ls = cameraRaw.watermarkLayers, index < ls.count else { return }
            mutate(&cameraRaw.watermarkLayers![index].geometry)
            cameraRaw.watermarkLayers![index].geometry = watermarkGeometryClampingOwnPosition(
                cameraRaw.watermarkLayers![index].geometry, assetAspect: assetAspectValue
            )
        }
    }

    private func watermarkSizeValueBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: {
                guard let layers = metadataViewModel.editingMetadata.cameraRaw?.watermarkLayers,
                      index < layers.count else { return 0 }
                return layers[index].geometry.sizeValue
            },
            set: { newValue in
                updateWatermarkGeometry(index) { $0.sizeValue = newValue }
                // The committed value now matches — drop the live-drag overlay override so it
                // reads straight from cameraRaw again (mirrors the position-handle drag's own
                // onCommit clearing dragWatermarkGeometry).
                dragWatermarkGeometry = nil
            }
        )
    }

    private func watermarkMarginValueBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: {
                guard let layers = metadataViewModel.editingMetadata.cameraRaw?.watermarkLayers,
                      index < layers.count else { return 0 }
                return layers[index].geometry.marginValue
            },
            set: { newValue in
                updateWatermarkGeometry(index) { $0.marginValue = newValue }
                dragWatermarkGeometry = nil
            }
        )
    }

    private func watermarkSizeDimensionBinding(_ index: Int) -> Binding<WatermarkDimension> {
        Binding(
            get: {
                guard let layers = metadataViewModel.editingMetadata.cameraRaw?.watermarkLayers,
                      index < layers.count else { return .width }
                return layers[index].geometry.sizeDimension
            },
            set: { newValue in
                updateWatermarkGeometry(index) { $0.sizeDimension = newValue }
                commitEditAdjustments()
            }
        )
    }

    private func watermarkSizeUnitBinding(_ index: Int) -> Binding<WatermarkSizeUnit> {
        Binding(
            get: {
                guard let layers = metadataViewModel.editingMetadata.cameraRaw?.watermarkLayers,
                      index < layers.count else { return .percent }
                return layers[index].geometry.sizeUnit
            },
            set: { newValue in
                updateWatermarkGeometry(index) { $0.sizeUnit = newValue }
                commitEditAdjustments()
            }
        )
    }

    private func watermarkMarginUnitBinding(_ index: Int) -> Binding<WatermarkMarginUnit> {
        Binding(
            get: {
                guard let layers = metadataViewModel.editingMetadata.cameraRaw?.watermarkLayers,
                      index < layers.count else { return .percent }
                return layers[index].geometry.marginUnit
            },
            set: { newValue in
                updateWatermarkGeometry(index) { $0.marginUnit = newValue }
                commitEditAdjustments()
            }
        )
    }

    /// Per-layer opacity (0–1) as a 0–100 slider value.
    private func watermarkOpacityBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: {
                guard let layers = metadataViewModel.editingMetadata.cameraRaw?.watermarkLayers,
                      index < layers.count else { return 100 }
                return layers[index].opacity * 100
            },
            set: { newValue in
                updateCameraRaw { cameraRaw in
                    guard let layers = cameraRaw.watermarkLayers, index < layers.count else { return }
                    cameraRaw.watermarkLayers?[index].opacity = min(max(newValue / 100, 0), 1)
                }
            }
        )
    }

    private func watermarkAssetIDBinding(_ index: Int) -> Binding<UUID?> {
        Binding(
            get: {
                guard let layers = metadataViewModel.editingMetadata.cameraRaw?.watermarkLayers,
                      index < layers.count else { return nil }
                return layers[index].libraryAssetID
            },
            set: { newValue in
                guard let newValue else { return }
                updateCameraRaw { cameraRaw in
                    guard let layers = cameraRaw.watermarkLayers, index < layers.count else { return }
                    cameraRaw.watermarkLayers?[index].libraryAssetID = newValue
                }
                commitEditAdjustments()
            }
        )
    }

    /// Per-mask opacity (`amount`, 0–1) as a 0–100 slider value. `amount` is non-optional and
    /// defaults to 1.0 (fully applied).
    private func maskAmountBinding(_ maskIndex: Int) -> Binding<Double> {
        Binding(
            get: {
                guard let masks = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments,
                      maskIndex < masks.count else { return 100 }
                return masks[maskIndex].amount * 100
            },
            set: { newValue in
                updateCameraRaw { cameraRaw in
                    guard let masks = cameraRaw.localAdjustments, maskIndex < masks.count else { return }
                    cameraRaw.localAdjustments?[maskIndex].amount = min(max(newValue / 100, 0), 1)
                }
            }
        )
    }

    private func maskDoubleBinding(_ maskIndex: Int, _ keyPath: WritableKeyPath<MaskAdjustment, Double?>) -> Binding<Double> {
        Binding(
            get: {
                guard let masks = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments,
                      maskIndex < masks.count else { return 0 }
                return masks[maskIndex][keyPath: keyPath] ?? 0
            },
            set: { newValue in
                updateCameraRaw { cameraRaw in
                    guard let masks = cameraRaw.localAdjustments, maskIndex < masks.count else { return }
                    cameraRaw.localAdjustments?[maskIndex][keyPath: keyPath] = abs(newValue) < 0.001 ? nil : newValue
                }
            }
        )
    }

    private func maskIntBinding(_ maskIndex: Int, _ keyPath: WritableKeyPath<MaskAdjustment, Int?>) -> Binding<Double> {
        Binding(
            get: {
                guard let masks = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments,
                      maskIndex < masks.count else { return 0 }
                return Double(masks[maskIndex][keyPath: keyPath] ?? 0)
            },
            set: { newValue in
                updateCameraRaw { cameraRaw in
                    guard let masks = cameraRaw.localAdjustments, maskIndex < masks.count else { return }
                    let intVal = Int(newValue.rounded())
                    cameraRaw.localAdjustments?[maskIndex][keyPath: keyPath] = intVal == 0 ? nil : intVal
                }
            }
        )
    }

    private func maskAnonymizerAmountBinding(_ maskIndex: Int) -> Binding<Double> {
        Binding(
            get: {
                guard let masks = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments,
                      maskIndex < masks.count else { return 0 }
                return masks[maskIndex].anonymizer?.amount ?? 0
            },
            set: { newValue in
                let clamped = min(max(newValue.rounded(), 0), 100)
                updateCameraRaw { cameraRaw in
                    guard let masks = cameraRaw.localAdjustments, maskIndex < masks.count else { return }
                    if clamped <= 0 {
                        cameraRaw.localAdjustments?[maskIndex].anonymizer?.amount = nil
                        if cameraRaw.localAdjustments?[maskIndex].anonymizer?.isEmpty == true {
                            cameraRaw.localAdjustments?[maskIndex].anonymizer = nil
                        }
                    } else {
                        if cameraRaw.localAdjustments?[maskIndex].anonymizer == nil {
                            cameraRaw.localAdjustments?[maskIndex].anonymizer = AnonymizerSettings()
                        }
                        cameraRaw.localAdjustments?[maskIndex].anonymizer?.amount = clamped
                    }
                }
                // Anonymizing wants full coverage — a partially-opaque mask would leak the
                // underlying detail through the pixelation. Nudge the brush to 100% flow so
                // subsequent strokes fully obscure (only for brush masks).
                if clamped > 0,
                   let masks = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments,
                   maskIndex < masks.count, masks[maskIndex].brush != nil {
                    maskInteraction.brushFlow = 1.0
                }
            }
        )
    }

    private func maskAnonymizerEnabledBinding(_ maskIndex: Int) -> Binding<Bool> {
        Binding(
            get: {
                guard let masks = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments,
                      maskIndex < masks.count else { return false }
                return AnonymizerToggleBehavior.isEnabled(masks[maskIndex].anonymizer)
            },
            set: { newValue in
                updateCameraRaw { cameraRaw in
                    guard let masks = cameraRaw.localAdjustments, maskIndex < masks.count else { return }
                    var anonymizer = masks[maskIndex].anonymizer
                    AnonymizerToggleBehavior.setEnabled(newValue, settings: &anonymizer)
                    cameraRaw.localAdjustments?[maskIndex].anonymizer = anonymizer
                }
                if newValue,
                   let masks = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments,
                   maskIndex < masks.count, masks[maskIndex].brush != nil {
                    maskInteraction.brushFlow = 1.0
                }
                commitEditAdjustments()
            }
        )
    }

    private func maskAnonymizerBlackOutBinding(_ maskIndex: Int) -> Binding<Bool> {
        Binding(
            get: {
                guard let masks = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments,
                      maskIndex < masks.count else { return false }
                return masks[maskIndex].anonymizer?.blackOut ?? false
            },
            set: { newValue in
                updateCameraRaw { cameraRaw in
                    guard let masks = cameraRaw.localAdjustments, maskIndex < masks.count else { return }
                    if newValue {
                        if cameraRaw.localAdjustments?[maskIndex].anonymizer == nil {
                            cameraRaw.localAdjustments?[maskIndex].anonymizer = AnonymizerSettings()
                        }
                        cameraRaw.localAdjustments?[maskIndex].anonymizer?.blackOut = true
                    } else {
                        cameraRaw.localAdjustments?[maskIndex].anonymizer?.blackOut = nil
                        if cameraRaw.localAdjustments?[maskIndex].anonymizer?.isEmpty == true {
                            cameraRaw.localAdjustments?[maskIndex].anonymizer = nil
                        }
                    }
                }
                // A Toggle has no "drag end" — every flip is a discrete commit.
                commitEditAdjustments()
            }
        )
    }

    private func addNewMask(center: CGPoint? = nil, cornerRadius: Double? = nil) {
        let existingCount = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments?.count ?? 0
        var geo = EllipseMaskGeometry()
        geo.cornerRadius = cornerRadius
        if let center {
            geo.centerX = Double(center.x)
            geo.centerY = Double(center.y)
        }
        // Make the mask a circle by compensating for image aspect ratio
        if let size = currentImageSize, size.height > 0 {
            geo.radiusY = geo.radiusX * size.width / size.height
        }
        // The default geometry is authored in the display frame; storage is sensor-frame.
        geo = maskGeometryForSensor(geo)
        let baseName = geo.isStandardEllipse ? "Mask" : "Rectangle"
        let newMask = MaskAdjustment(name: "\(baseName) \(existingCount + 1)", geometry: geo)
        updateCameraRaw { cameraRaw in
            if cameraRaw.localAdjustments == nil {
                cameraRaw.localAdjustments = []
            }
            cameraRaw.localAdjustments?.append(newMask)
            // Only extend an explicit order; a nil order means "canonical" and the resolver
            // appends new masks at the end automatically.
            if cameraRaw.layerOrder != nil {
                cameraRaw.layerOrder?.append(.mask(newMask.id))
            }
        }
        selectedLayer = .mask(newMask.id)
        commitEditAdjustments()
    }

    /// Adds a reorderable full-frame adjustment node while leaving the permanent primary Global
    /// node untouched. The oversized zero-feather ellipse is an Adobe Camera Raw fallback;
    /// Photo Agent uses `fullFrame` for exact edge-to-edge coverage independent of aspect ratio.
    private func addNewGlobalLayer() {
        let existingCount = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments?
            .filter(\.isFullFrame).count ?? 0
        var fallbackGeometry = EllipseMaskGeometry()
        fallbackGeometry.centerX = 0.5
        fallbackGeometry.centerY = 0.5
        fallbackGeometry.radiusX = 2
        fallbackGeometry.radiusY = 2
        fallbackGeometry.feather = 0
        let newLayer = MaskAdjustment(
            name: "Global \(existingCount + 2)",
            geometry: fallbackGeometry,
            fullFrame: true
        )
        updateCameraRaw { cameraRaw in
            if cameraRaw.localAdjustments == nil {
                cameraRaw.localAdjustments = []
            }
            cameraRaw.localAdjustments?.append(newLayer)
            if cameraRaw.layerOrder != nil {
                cameraRaw.layerOrder?.append(.mask(newLayer.id))
            }
        }
        selectedLayer = .mask(newLayer.id)
        commitEditAdjustments()
    }

    private func addNewColorTransformLayer() {
        let existingCount = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments?
            .filter { $0.colorTransform != nil }.count ?? 0
        var fallbackGeometry = EllipseMaskGeometry()
        fallbackGeometry.centerX = 0.5
        fallbackGeometry.centerY = 0.5
        fallbackGeometry.radiusX = 2
        fallbackGeometry.radiusY = 2
        fallbackGeometry.feather = 0
        let newLayer = MaskAdjustment(
            name: "Color Transform \(existingCount + 1)",
            geometry: fallbackGeometry,
            fullFrame: true,
            colorTransform: ColorTransformSettings()
        )
        updateCameraRaw { cameraRaw in
            if cameraRaw.localAdjustments == nil {
                cameraRaw.localAdjustments = []
            }
            cameraRaw.localAdjustments?.append(newLayer)
            if cameraRaw.layerOrder != nil {
                cameraRaw.layerOrder?.append(.mask(newLayer.id))
            }
        }
        selectedLayer = .mask(newLayer.id)
        commitEditAdjustments()
    }

    private func beginColorLUTImport(for layerID: UUID) {
        cancelColorLUTImport()
        importingLUTForLayerID = layerID
        isShowingLUTImporter = true
    }

    private func cancelColorLUTImport() {
        colorLUTImportTask?.cancel()
        colorLUTImportTask = nil
        colorLUTImportRequestID = nil
    }

    private func importColorLUT(_ result: Result<[URL], any Error>) {
        guard let layerID = importingLUTForLayerID else { return }
        importingLUTForLayerID = nil
        cancelColorLUTImport()

        do {
            let url = try result.get().first
            guard let url else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            let requestID = UUID()
            colorLUTImportRequestID = requestID
            colorLUTImportTask = Task { @MainActor in
                defer {
                    if accessed { url.stopAccessingSecurityScopedResource() }
                    if colorLUTImportRequestID == requestID {
                        colorLUTImportRequestID = nil
                        colorLUTImportTask = nil
                    }
                }
                do {
                    let importResult = try await ColorLUTImportService.shared.loadLUT(
                        from: url,
                        requestID: requestID
                    )
                    guard colorLUTImportRequestID == requestID else { return }
                    switch importResult {
                    case .loaded(let snapshot):
                        let parsed = try CubeLUTParser.parse(snapshot.data)
                        guard colorLUTImportRequestID == requestID, !Task.isCancelled else { return }
                        let displayName = parsed.title?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let name = displayName.flatMap { $0.isEmpty ? nil : $0 }
                            ?? snapshot.sourceURL.deletingPathExtension().lastPathComponent
                        updateCameraRaw { cameraRaw in
                            guard let index = cameraRaw.localAdjustments?
                                .firstIndex(where: { $0.id == layerID }),
                                  var transform = cameraRaw.localAdjustments?[index].colorTransform
                            else { return }
                            transform.mode = .lut
                            transform.lutName = name
                            transform.lutData = snapshot.data
                            cameraRaw.localAdjustments?[index].colorTransform = transform
                        }
                        commitEditAdjustments()
                    case .cancelledBeforeRead, .cancelledAfterRead:
                        return
                    }
                } catch {
                    guard colorLUTImportRequestID == requestID, !Task.isCancelled else { return }
                    colorTransformError = error.localizedDescription
                }
            }
        } catch {
            colorTransformError = error.localizedDescription
        }
    }

    // MARK: - AI subject/object mask

    private func startAIMaskSelection(replacing maskID: UUID? = nil) {
        guard canEditSingleImage, sourceCIImage != nil, !isGeneratingAIMask else { return }
        clearMaskMattePreview()
        maskInteraction.beginExclusiveSelection()
        isPickingWhiteBalance = false
        wbPickDragRect = nil
        guard aiMaskSelection.beginSelection(
            replacing: maskID,
            resetsTarget: maskID == nil
        ) else { return }
        syncMaskOverlayTarget()
    }

    private func cancelAIMaskSelection() {
        aiMaskSelection.cancelSelection()
        NSCursor.arrow.set()
    }

    /// Reverse the crop-straighten display rotation after pane→viewport mapping. Vision analyzes
    /// the un-straightened `sourceCIImage`, so the click must land in that same source frame.
    private func aiSourcePoint(fromDisplayedUV point: CGPoint) -> CGPoint {
        var marker = WatermarkGeometry()
        marker.centerX = Double(point.x)
        marker.centerY = Double(point.y)
        marker = marker.rotatedInDisplay(byDegrees: displayCropAngle, aspect: maskDisplayAspect)
        return CGPoint(
            x: min(max(marker.centerX, 0), 1),
            y: min(max(marker.centerY, 0), 1)
        )
    }

    private func performAIMaskPick(
        panePoint: CGPoint,
        paneSize: CGSize,
        viewportOrigin: SIMD2<Float>,
        viewportSize: SIMD2<Float>
    ) {
        guard isSelectingAIMask, !isGeneratingAIMask,
              let source = sourceCIImage,
              let imageURL = selectedImageURL,
              let displayedUV = EditPreviewCoordinateMapper.displayUV(
                  forPanePoint: panePoint,
                  paneSize: paneSize,
                  viewportOrigin: viewportOrigin,
                  viewportSize: viewportSize
              )
        else { return }

        let sourcePoint = aiSourcePoint(fromDisplayedUV: displayedUV)
        aiMaskSelection.generate(
            from: source,
            sourcePoint: sourcePoint,
            sourceOrientation: selectedImageOrientation,
            imageURL: imageURL
        ) { generated, replacementID in
            installGeneratedAIMask(generated, replacing: replacementID)
        }
    }

    private func installGeneratedAIMask(
        _ generated: GeneratedAIMask,
        replacing replacementID: UUID?
    ) {
        let targetID: UUID
        if let replacementID,
           metadataViewModel.editingMetadata.cameraRaw?.localAdjustments?
            .contains(where: { $0.id == replacementID }) == true {
            updateCameraRaw { cameraRaw in
                guard let index = cameraRaw.localAdjustments?
                    .firstIndex(where: { $0.id == replacementID }) else { return }
                let previousRefinements = cameraRaw.localAdjustments?[index].aiMask
                var replacement = generated.raster
                replacement.blackPoint = previousRefinements?.blackPoint
                replacement.whitePoint = previousRefinements?.whitePoint
                replacement.blurRadius = previousRefinements?.blurRadius
                cameraRaw.localAdjustments?[index].brush = nil
                cameraRaw.localAdjustments?[index].aiMask = replacement
            }
            targetID = replacementID
        } else {
            let count = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments?.count ?? 0
            let newMask = MaskAdjustment(name: "AI Mask \(count + 1)", aiMask: generated.raster)
            updateCameraRaw { cameraRaw in
                if cameraRaw.localAdjustments == nil { cameraRaw.localAdjustments = [] }
                cameraRaw.localAdjustments?.append(newMask)
                if cameraRaw.layerOrder != nil {
                    cameraRaw.layerOrder?.append(.mask(newMask.id))
                }
            }
            targetID = newMask.id
        }

        selectedLayer = .mask(targetID)
        if let pipeline = metalPipeline, pipeline.hasSourceTexture {
            pipeline.updateParams(settingsForPipeline(metadataViewModel.editingMetadata.cameraRaw))
            metalCoordinator.requestRedraw()
        }
        syncMaskOverlayTarget()
        commitEditAdjustments()
    }

    // MARK: - Watermark layers

    /// Adds a new watermark layer using the first (alphabetically) library asset, defaulting
    /// to the bottom-right corner of the margin-inset safe area per spec. If the library is
    /// empty, prompts the user to import one from Settings instead of adding a layer with no
    /// image to show.
    private func addNewWatermarkLayer() {
        guard let defaultAsset = WatermarkStore.shared.allAssets().first else {
            showWatermarkLibraryEmptyAlert = true
            return
        }
        let existingCount = metadataViewModel.editingMetadata.cameraRaw?.watermarkLayers?.count ?? 0
        var geo = WatermarkGeometry()   // defaults to the bottom-right corner
        // Use this asset's own remembered size/margin (Settings ▸ Watermarks ▸ Default
        // Placement) rather than the bare app-wide default (20% width / 10% margin).
        geo.sizeDimension = defaultAsset.defaultSizeDimension
        geo.sizeUnit = defaultAsset.defaultSizeUnit
        geo.sizeValue = defaultAsset.defaultSizeValue
        geo.marginUnit = defaultAsset.defaultMarginUnit
        geo.marginValue = defaultAsset.defaultMarginValue
        if let size = currentImageSize, size.width > 0, size.height > 0 {
            geo = geo.clamped(assetAspect: defaultAsset.aspectRatio, imageWidth: size.width, imageHeight: size.height)
        }
        geo = watermarkGeometryForSensor(geo)
        let newLayer = WatermarkLayer(name: "Watermark \(existingCount + 1)", libraryAssetID: defaultAsset.id, geometry: geo)
        updateCameraRaw { cameraRaw in
            if cameraRaw.watermarkLayers == nil { cameraRaw.watermarkLayers = [] }
            cameraRaw.watermarkLayers?.append(newLayer)
            if cameraRaw.layerOrder != nil {
                cameraRaw.layerOrder?.append(.watermark(newLayer.id))
            }
        }
        selectedLayer = .watermark(newLayer.id)
        commitEditAdjustments()
    }

    private func deleteSelectedWatermark() {
        guard case .watermark(let id) = selectedLayer,
              let layers = metadataViewModel.editingMetadata.cameraRaw?.watermarkLayers,
              let idx = layers.firstIndex(where: { $0.id == id }) else { return }
        updateCameraRaw { cameraRaw in
            cameraRaw.watermarkLayers?.removeAll { $0.id == id }
            cameraRaw.layerOrder?.removeAll { $0 == .watermark(id) }
            if cameraRaw.watermarkLayers?.isEmpty == true {
                cameraRaw.watermarkLayers = nil
            }
        }
        let remaining = metadataViewModel.editingMetadata.cameraRaw?.watermarkLayers ?? []
        if remaining.isEmpty {
            selectedLayer = .global
        } else {
            selectedLayer = .watermark(remaining[min(idx, remaining.count - 1)].id)
        }
        commitEditAdjustments()
    }

    private func toggleWatermarkEnabled(_ id: UUID) {
        updateCameraRaw { cameraRaw in
            guard let i = cameraRaw.watermarkLayers?.firstIndex(where: { $0.id == id }) else { return }
            cameraRaw.watermarkLayers?[i].enabled.toggle()
        }
        commitEditAdjustments()
    }

    /// Mute / delete controls for the selected watermark layer, shown beneath the strip —
    /// mirrors `maskActionRow` but omits invert (not a meaningful concept for a watermark).
    @ViewBuilder
    private func watermarkActionRow(_ id: UUID) -> some View {
        if let layer = metadataViewModel.editingMetadata.cameraRaw?.watermarkLayers?.first(where: { $0.id == id }) {
            HStack(spacing: 10) {
                Button {
                    toggleWatermarkEnabled(id)
                } label: {
                    Image(systemName: layer.enabled ? "eye" : "eye.slash")
                        .font(.system(size: 11))
                        .foregroundStyle(layer.enabled ? Color.secondary : Color.red)
                }
                .buttonStyle(.plain)
                .help(layer.enabled ? "Mute watermark effect" : "Enable watermark effect")

                Spacer()

                Button {
                    deleteSelectedWatermark()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete watermark layer")
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: - Brush paint tool

    /// Creates an empty freeform brush mask, selects it, and returns its id. Called lazily on the
    /// first paint gesture when no brush mask is selected (like `addNewMask` for ellipses).
    private func addNewBrushMask() -> UUID {
        let existingCount = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments?.count ?? 0
        let newMask = MaskAdjustment(name: "Brush \(existingCount + 1)", brush: BrushMaskGeometry(strokes: []))
        updateCameraRaw { cameraRaw in
            if cameraRaw.localAdjustments == nil { cameraRaw.localAdjustments = [] }
            cameraRaw.localAdjustments?.append(newMask)
            if cameraRaw.layerOrder != nil {
                cameraRaw.layerOrder?.append(.mask(newMask.id))
            }
        }
        selectedLayer = .mask(newMask.id)
        return newMask.id
    }

    /// The GPU alpha-array slice index for a brush mask, mirroring `MetalEditPipeline.updateParams`'
    /// slice assignment (enabled masks in order, capped to the pipeline's mask limit, brush ones
    /// numbered as encountered). Returns nil if the id isn't an enabled brush mask.
    private func brushSliceIndex(forMaskID id: UUID) -> Int? {
        guard let masks = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments else { return nil }
        var slice = 0
        for mask in masks.filter({ $0.enabled }).prefix(8) {
            if mask.id == id { return mask.brush != nil ? slice : nil }
            if mask.brush != nil || mask.aiMask != nil { slice += 1 }
        }
        return nil
    }

    /// Maps a display-frame stroke to the sensor (XMP) frame for storage — the inverse of the
    /// EXIF-orientation transform the render path applies. (Crop straighten isn't applied to brush
    /// dabs; painting on a straightened-but-unconfirmed image is an edge case, flagged for later.)
    private func brushStrokeForSensor(_ stroke: BrushStroke) -> BrushStroke {
        let orientation = selectedImageOrientation
        guard orientation > 1 else { return stroke }
        let g = BrushMaskGeometry(strokes: [stroke]).transformedForSensor(orientation: orientation)
        return g.strokes.first ?? stroke
    }

    /// `onStrokeBegan`: resolve the target brush mask (selected one, or a fresh mask), make sure
    /// the pipeline has rebuilt so the mask's alpha slice exists, and return that slice index.
    private func ensureBrushTarget() -> Int? {
        let targetID: UUID
        if let id = selectedMaskID,
           let masks = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments,
           masks.first(where: { $0.id == id })?.brush != nil {
            targetID = id
        } else {
            targetID = addNewBrushMask()
        }
        // Rebuild params so a freshly-created mask's alpha slice is allocated before live
        // stamping, and turn on the red coverage overlay for this mask so the stroke is visible
        // as it's painted (auto-hidden once the mask gets an adjustment).
        metalPipeline?.maskOverlayMaskID = targetID
        if let pipeline = metalPipeline, pipeline.hasSourceTexture {
            pipeline.updateParams(settingsForPipeline(metadataViewModel.editingMetadata.cameraRaw))
        }
        return brushSliceIndex(forMaskID: targetID)
    }

    /// Drives the ACR-style red mask-coverage overlay: shows it for the selected mask while the
    /// brush tool is active or a brush mask is selected, and clears it otherwise. The kernel
    /// itself hides the tint once the mask has an adjustment, so this only tracks selection.
    private func syncMaskOverlayTarget() {
        guard let pipeline = metalPipeline else { return }
        pipeline.maskOverlayMaskID = (isBrushPainting || selectedMaskIsBrush || selectedMaskIsAI)
            ? selectedMaskID : nil
        if pipeline.hasSourceTexture {
            pipeline.updateParams(settingsForPipeline(metadataViewModel.editingMetadata.cameraRaw))
            metalCoordinator.requestRedraw()
        }
    }

    /// Replaces the edited image with the selected mask's black/white coverage while its tool
    /// icon is hovered. The pipeline keeps this preview editor-local; its clean-feed mirror still
    /// receives the ordinary settings and therefore never shows the temporary matte.
    private func setMaskMattePreview(maskID: UUID, visible: Bool) {
        guard maskInteraction.setMattePreview(maskID: maskID, visible: visible) else { return }
        let nextID = maskInteraction.mattePreviewMaskID
        guard let pipeline = metalPipeline else { return }
        pipeline.maskMattePreviewMaskID = nextID
        if pipeline.hasSourceTexture {
            pipeline.updateParams(settingsForPipeline(metadataViewModel.editingMetadata.cameraRaw))
            metalCoordinator.requestRedraw()
        }
    }

    private func clearMaskMattePreview() {
        let clearedCoordinatorPreview = maskInteraction.clearMattePreview()
        guard clearedCoordinatorPreview || metalPipeline?.maskMattePreviewMaskID != nil else { return }
        guard let pipeline = metalPipeline else { return }
        pipeline.maskMattePreviewMaskID = nil
        if pipeline.hasSourceTexture {
            pipeline.updateParams(settingsForPipeline(metadataViewModel.editingMetadata.cameraRaw))
            metalCoordinator.requestRedraw()
        }
    }

    /// `onStrokeChanged`: stamp the incremental dabs straight into the GPU alpha slice for
    /// immediate feedback (the dabs are already display-frame, matching the display-oriented
    /// alpha texture), then request a redraw. Transient — the model isn't touched until commit.
    private func liveBrushStamp(_ stroke: BrushStroke, layer: Int) {
        guard let pipeline = metalPipeline, pipeline.hasSourceTexture else { return }
        pipeline.stampBrushStroke(stroke, layer: layer)
        metalCoordinator.requestRedraw()
    }

    /// `onStrokeEnded`: append the finished gesture to the selected brush mask as ONE undo entry,
    /// then rebuild the authoritative alpha from the model.
    private func commitBrushStroke(_ stroke: BrushStroke) {
        guard let id = selectedMaskID else { return }
        let sensorStroke = brushStrokeForSensor(stroke)
        updateCameraRaw { cameraRaw in
            guard let idx = cameraRaw.localAdjustments?.firstIndex(where: { $0.id == id }) else { return }
            if cameraRaw.localAdjustments?[idx].brush == nil {
                cameraRaw.localAdjustments?[idx].brush = BrushMaskGeometry(strokes: [])
            }
            cameraRaw.localAdjustments?[idx].brush?.strokes.append(sensorStroke)
        }
        if let pipeline = metalPipeline, pipeline.hasSourceTexture {
            pipeline.updateParams(settingsForPipeline(metadataViewModel.editingMetadata.cameraRaw))
            metalCoordinator.requestRedraw()
        }
        commitEditAdjustments()
    }

    /// The paint overlay, parameterised by the region's viewport so it works in both the normal-fit
    /// and crop-applied preview layouts.
    @ViewBuilder
    private func brushOverlay(viewportOrigin: SIMD2<Float>, viewportSize: SIMD2<Float>, viewSize: CGSize) -> some View {
        if isBrushPainting, !isShowingBefore, canEditSingleImage, let imgSize = currentImageSize {
            BrushMaskOverlayRepresentable(
                viewportOrigin: viewportOrigin,
                viewportSize: viewportSize,
                viewSize: viewSize,
                imageSize: imgSize,
                radius: brushRadius,
                hardness: brushHardness,
                flow: brushFlow,
                erase: brushErase,
                onStrokeBegan: { ensureBrushTarget() },
                onStrokeChanged: { stroke, layer in liveBrushStamp(stroke, layer: layer) },
                onStrokeEnded: { stroke in commitBrushStroke(stroke) },
                onBrushSettingsChanged: { radius, hardness in
                    maskInteraction.brushRadius = radius
                    maskInteraction.brushHardness = hardness
                }
            )
            .frame(width: viewSize.width, height: viewSize.height)
        }
    }

    @ViewBuilder
    private func aiMaskSelectionOverlay(
        viewportOrigin: SIMD2<Float>, viewportSize: SIMD2<Float>, viewSize: CGSize
    ) -> some View {
        if isSelectingAIMask, !isShowingBefore, canEditSingleImage {
            AIMaskPickOverlay(isEnabled: !isGeneratingAIMask) { panePoint in
                performAIMaskPick(
                    panePoint: panePoint,
                    paneSize: viewSize,
                    viewportOrigin: viewportOrigin,
                    viewportSize: viewportSize
                )
            }
            .frame(width: viewSize.width, height: viewSize.height)
            .overlay(alignment: .top) {
                Label(
                    isGeneratingAIMask ? "Finding selection…" : "Click a face, person, or object",
                    systemImage: isGeneratingAIMask ? "sparkles" : "viewfinder"
                )
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 12)
                .allowsHitTesting(false)
            }
        }
    }

    private func deleteSelectedMask() {
        guard case .mask(let id) = selectedLayer,
              let masks = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments,
              let idx = masks.firstIndex(where: { $0.id == id }) else { return }
        updateCameraRaw { cameraRaw in
            cameraRaw.localAdjustments?.removeAll { $0.id == id }
            cameraRaw.layerOrder?.removeAll { $0 == .mask(id) }
            if cameraRaw.localAdjustments?.isEmpty == true {
                cameraRaw.localAdjustments = nil
            }
        }
        // Select the mask that now occupies the deleted slot (or the last one), else Global.
        let remaining = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments ?? []
        if remaining.isEmpty {
            selectedLayer = .global
        } else {
            selectedLayer = .mask(remaining[min(idx, remaining.count - 1)].id)
        }
        commitEditAdjustments()
    }

    /// Command-W treats every selected node as something that can be "closed": local nodes are
    /// removed, while the permanent Global node has only its own adjustments reset.
    private func removeOrResetSelectedEditLayer() {
        switch selectedLayer {
        case .global:
            resetGlobalLayerAdjustments()
        case .mask:
            deleteSelectedMask()
        case .watermark:
            deleteSelectedWatermark()
        }
    }

    private func resetGlobalLayerAdjustments() {
        guard let current = metadataViewModel.editingMetadata.cameraRaw else {
            showCopyPasteFeedback("Global layer is already reset")
            return
        }
        var reset = current
        GlobalLayerResetBehavior.reset(&reset, isRaw: isSelectedImageRaw)
        guard reset != current else {
            showCopyPasteFeedback("Global layer is already reset")
            return
        }
        updateCameraRaw { cameraRaw in
            GlobalLayerResetBehavior.reset(&cameraRaw, isRaw: isSelectedImageRaw)
        }
        commitEditAdjustments()
        showCopyPasteFeedback("Global layer reset")
    }

    private var isSelectedImageRaw: Bool {
        guard let url = selectedImageURL else { return false }
        return SupportedImageFormats.isRaw(url: url)
    }

    private var hasColorAdjustments: Bool {
        guard let cameraRaw = metadataViewModel.editingMetadata.cameraRaw else { return false }
        return cameraRaw.temperature != nil
            || cameraRaw.tint != nil
            || cameraRaw.incrementalTemperature != nil
            || cameraRaw.incrementalTint != nil
            || cameraRaw.saturation != nil
            || cameraRaw.vibrance != nil
            || cameraRaw.globalDensity != nil
    }

    private var hasExposureAdjustments: Bool {
        guard let cameraRaw = metadataViewModel.editingMetadata.cameraRaw else { return false }
        return cameraRaw.exposure2012 != nil
            || cameraRaw.contrast2012 != nil
            || cameraRaw.highlights2012 != nil
            || cameraRaw.shadows2012 != nil
            || cameraRaw.whites2012 != nil
            || cameraRaw.blacks2012 != nil
    }

    private var hasDetailAdjustments: Bool {
        guard let cameraRaw = metadataViewModel.editingMetadata.cameraRaw else { return false }
        return cameraRaw.sharpness != nil
            || cameraRaw.clarity2012 != nil
            || cameraRaw.dehaze != nil
    }

    private var hasHSLAdjustments: Bool {
        !(metadataViewModel.editingMetadata.cameraRaw?.hslAdjustments?.isEmpty ?? true)
    }

    private var hasAnonymizerAdjustments: Bool {
        !(metadataViewModel.editingMetadata.cameraRaw?.anonymizer?.isEmpty ?? true)
    }

    private var hasFilmAdjustments: Bool {
        !(metadataViewModel.editingMetadata.cameraRaw?.filmEmulation?.isEmpty ?? true)
    }

    private func resetColorAdjustments() {
        updateCameraRaw { cameraRaw in
            cameraRaw.whiteBalance = isSelectedImageRaw ? "As Shot" : nil
            cameraRaw.temperature = nil
            cameraRaw.tint = nil
            cameraRaw.incrementalTemperature = nil
            cameraRaw.incrementalTint = nil
            cameraRaw.saturation = nil
            cameraRaw.vibrance = nil
            cameraRaw.globalDensity = nil
        }
        commitEditAdjustments()
    }

    private func resetExposureAdjustments() {
        updateCameraRaw { cameraRaw in
            cameraRaw.exposure2012 = nil
            cameraRaw.contrast2012 = nil
            cameraRaw.highlights2012 = nil
            cameraRaw.shadows2012 = nil
            cameraRaw.whites2012 = nil
            cameraRaw.blacks2012 = nil
        }
        commitEditAdjustments()
    }

    private func resetDetailAdjustments() {
        updateCameraRaw { cameraRaw in
            cameraRaw.sharpness = nil
            cameraRaw.clarity2012 = nil
            cameraRaw.dehaze = nil
        }
        commitEditAdjustments()
    }

    private func resetHSLAdjustments() {
        updateCameraRaw { cameraRaw in
            cameraRaw.hslAdjustments = nil
        }
        commitEditAdjustments()
    }

    private func resetAnonymizerAdjustments() {
        updateCameraRaw { cameraRaw in
            cameraRaw.anonymizer = nil
        }
        commitEditAdjustments()
    }

    private func resetFilmAdjustments() {
        updateCameraRaw { cameraRaw in
            cameraRaw.filmEmulation = nil
        }
        commitEditAdjustments()
    }

    private func resetDevelopAdjustments() {
        resetCropZoom()
        selectedLayer = .global
        updateCameraRaw { cameraRaw in
            cameraRaw.whiteBalance = isSelectedImageRaw ? "As Shot" : nil
            cameraRaw.temperature = nil
            cameraRaw.tint = nil
            cameraRaw.incrementalTemperature = nil
            cameraRaw.incrementalTint = nil
            cameraRaw.exposure2012 = nil
            cameraRaw.contrast2012 = nil
            cameraRaw.highlights2012 = nil
            cameraRaw.shadows2012 = nil
            cameraRaw.whites2012 = nil
            cameraRaw.blacks2012 = nil
            cameraRaw.saturation = nil
            cameraRaw.vibrance = nil
            cameraRaw.globalDensity = nil
            cameraRaw.sharpness = nil
            cameraRaw.clarity2012 = nil
            cameraRaw.dehaze = nil
            cameraRaw.localAdjustments = nil
            cameraRaw.anonymizer = nil
            cameraRaw.filmEmulation = nil
            cameraRaw.crop = CameraRawCrop(
                top: 0,
                left: 0,
                bottom: 1,
                right: 1,
                angle: 0,
                hasCrop: false
            )
        }
        commitDevelopReset()
    }

    private func resetDevelopAdjustmentsKeepingCrop() {
        updateCameraRaw { cameraRaw in
            cameraRaw.whiteBalance = isSelectedImageRaw ? "As Shot" : nil
            cameraRaw.temperature = nil
            cameraRaw.tint = nil
            cameraRaw.incrementalTemperature = nil
            cameraRaw.incrementalTint = nil
            cameraRaw.exposure2012 = nil
            cameraRaw.contrast2012 = nil
            cameraRaw.highlights2012 = nil
            cameraRaw.shadows2012 = nil
            cameraRaw.whites2012 = nil
            cameraRaw.blacks2012 = nil
            cameraRaw.saturation = nil
            cameraRaw.vibrance = nil
            cameraRaw.globalDensity = nil
            cameraRaw.sharpness = nil
            cameraRaw.clarity2012 = nil
            cameraRaw.dehaze = nil
            cameraRaw.toneCurve = nil
            cameraRaw.localAdjustments = nil
            cameraRaw.anonymizer = nil
            cameraRaw.filmEmulation = nil
        }
        selectedLayer = .global
        commitDevelopReset()
    }

    private var saveButtonLabel: String {
        let formatName: String
        if isHDREnabled {
            let format = ExportFormatHDR(rawValue: UserDefaults.standard.string(forKey: UserDefaultsKeys.exportFormatHDR) ?? "") ?? .jxl
            formatName = "HDR \(format.displayName)"
        } else {
            let format = ExportFormatSDR(rawValue: UserDefaults.standard.string(forKey: UserDefaultsKeys.exportFormatSDR) ?? "") ?? .jpeg
            formatName = format.displayName
        }
        return isSavingRenderedJPEG ? "Saving \(formatName)..." : "Save \(formatName)"
    }

    private func saveCurrentRenderedImage() {
        guard !isSavingRenderedJPEG,
              let selectedImageURL else { return }
        let settings = metadataViewModel.editingMetadata.cameraRaw
        let maskCount = settings?.localAdjustments?.count ?? 0
        editLog.info("saveCurrentRenderedImage: \(maskCount) mask(s), exp=\(settings?.exposure2012 ?? 0)")
        if maskCount > 0, let masks = settings?.localAdjustments {
            for (i, m) in masks.enumerated() {
                editLog.info("  save mask[\(i)]: exp=\(m.exposure ?? 0) enabled=\(m.enabled)")
            }
        }
        let hdr = isHDREnabled
        isSavingRenderedJPEG = true

        Task {
            defer { isSavingRenderedJPEG = false }
            do {
                let outputFolder = selectedImageURL.deletingLastPathComponent().appendingPathComponent("Edited", isDirectory: true)
                let directoryCommit = try await ExportDirectoryService.shared.ensureDirectory(
                    at: outputFolder
                )
                // Directory creation is a synchronous durable commit once the filesystem call
                // starts. If cancellation arrived during it, retain the folder but do not begin
                // the substantially more expensive render.
                guard !directoryCommit.cancellationRequestedAfterCommit else { return }
                try Task.checkCancellation()
                let engine = browserViewModel.writeEngine
                let failureTracker = MetadataFailureTracker()
                let copier: EditedImageRenderer.MetadataCopier = { src, dst in
                    do {
                        try await engine.copyMetadataToRenderedFile(
                            from: src, to: dst, bakedCameraRaw: settings)
                    } catch {
                        await failureTracker.recordCopyFailure(src.lastPathComponent)
                    }
                }
                let outputURL = try await Task.detached(priority: .userInitiated) {
                    try await EditedImageRenderer.render(from: selectedImageURL, cameraRaw: settings, isHDR: hdr, outputFolder: outputFolder, metadataCopier: copier)
                }.value
                browserViewModel.thumbnailService.invalidateThumbnail(for: outputURL)
                if await !failureTracker.metadataCopyFailures.isEmpty {
                    saveError = "Image saved but metadata copy failed — IPTC data may be missing"
                }
            } catch is CancellationError {
                // Cancellation before the directory commit writes nothing; cancellation after a
                // committed directory intentionally leaves that harmless directory in place.
            } catch {
                saveError = "Failed to save image: \(error.localizedDescription)"
            }
        }
    }

    private func signedIntString(_ value: Double) -> String {
        let intValue = Int(value.rounded())
        if intValue > 0 { return "+\(intValue)" }
        return "\(intValue)"
    }

    private func signedDoubleString(_ value: Double, precision: Int = 2) -> String {
        let format = "%.\(precision)f"
        let absValue = String(format: format, abs(value))
        if value > 0 { return "+\(absValue)" }
        if value < 0 { return "-\(absValue)" }
        return absValue
    }

    /// The current edit buffer is newer than the filmstrip model until the next commit, so use
    /// it when the clicked thumbnail is the actively edited image. Other thumbnails use their
    /// already-loaded Camera Raw settings.
    private func filmstripSettings(for image: ImageFile) -> CameraRawSettings? {
        if image.url == selectedImageURL,
           let current = metadataViewModel.editingMetadata.cameraRaw {
            return current
        }
        return image.cameraRawSettings
    }

    private func copyFilmstripSettings(from image: ImageFile) {
        guard let settings = filmstripSettings(for: image) else {
            showCopyPasteFeedback("No develop settings")
            return
        }
        browserViewModel.copiedCameraRawSettings = settings
        showCopyPasteFeedback("Copied from \(image.filename)")
    }

    /// Apply the shared settings clipboard to explicit targets without changing which thumbnails
    /// are selected. A single active-image target takes the live edit-buffer path; every other
    /// case uses the existing multi-image writer.
    private func pasteCopiedSettings(to urls: Set<URL>) {
        guard let settings = browserViewModel.copiedCameraRawSettings, !urls.isEmpty else { return }
        if urls.count == 1, urls.first == selectedImageURL {
            pasteCameraRawSettings(settings, includeCrop: false)
        } else {
            pasteToMultipleImages(settings, urls: urls, includeCrop: false)
        }
        showCopyPasteFeedback("Pasted to \(urls.count) image\(urls.count == 1 ? "" : "s")")
    }

    /// Resolve-style direct copy: the clicked thumbnail is the source and the selection remains
    /// the destination. Crop stays opt-in, matching every other ordinary settings paste.
    private func applyFilmstripSettingsFromImageToCurrentSelection(_ image: ImageFile) {
        guard let settings = filmstripSettings(for: image) else {
            showCopyPasteFeedback("No develop settings")
            return
        }
        let targets = browserViewModel.selectedImageIDs
        guard !targets.isEmpty else { return }
        browserViewModel.copiedCameraRawSettings = settings
        pasteCopiedSettings(to: targets)
    }

    private func pasteCameraRawSettings(_ source: CameraRawSettings, includeCrop: Bool) {
        updateCameraRaw { cameraRaw in
            cameraRaw.whiteBalance = source.whiteBalance
            cameraRaw.temperature = source.temperature
            cameraRaw.tint = source.tint
            cameraRaw.incrementalTemperature = source.incrementalTemperature
            cameraRaw.incrementalTint = source.incrementalTint
            cameraRaw.exposure2012 = source.exposure2012
            cameraRaw.contrast2012 = source.contrast2012
            cameraRaw.highlights2012 = source.highlights2012
            cameraRaw.shadows2012 = source.shadows2012
            cameraRaw.whites2012 = source.whites2012
            cameraRaw.blacks2012 = source.blacks2012
            cameraRaw.saturation = source.saturation
            cameraRaw.vibrance = source.vibrance
            cameraRaw.globalDensity = source.globalDensity
            cameraRaw.sharpness = source.sharpness
            cameraRaw.clarity2012 = source.clarity2012
            cameraRaw.dehaze = source.dehaze
            cameraRaw.toneCurve = source.toneCurve
            cameraRaw.hslAdjustments = source.hslAdjustments
            cameraRaw.filmEmulation = source.filmEmulation
            // Paste masks only when the source carries some — pasting from a
            // mask-less image shouldn't strip the target's masks. Fresh IDs so
            // the pasted masks are independent of the source's.
            if let masks = source.localAdjustments, !masks.isEmpty {
                cameraRaw.localAdjustments = masks.map { mask in
                    var copy = mask
                    copy.id = UUID()
                    return copy
                }
            }
            if includeCrop {
                cameraRaw.crop = source.crop
            }
        }
        commitEditAdjustments()
    }

    private func applyDevelopTemplate(_ template: DevelopTemplate) {
        let current = metadataViewModel.editingMetadata.cameraRaw
        let applied = template.settingsForApplication(preserving: current)

        resetCropZoom()
        selectedLayer = .global
        maskInteraction.stopBrushPainting()
        updateCameraRaw { cameraRaw in
            cameraRaw = applied
        }

        if metadataViewModel.editingMetadata.cameraRaw == nil {
            commitDevelopReset()
        } else {
            commitEditAdjustments()
        }
        showCopyPasteFeedback("Applied \(template.name)")
    }

    private func pasteToMultipleImages(_ source: CameraRawSettings, urls: Set<URL>, includeCrop: Bool) {
        guard let folderURL = metadataViewModel.currentFolderURL else { return }

        var cameraRaw = source
        if !includeCrop {
            cameraRaw.crop = nil
        }
        cameraRaw.hasSettings = true

        // Update in-memory ImageFile state for immediate visual feedback
        for url in urls {
            if let index = browserViewModel.urlToImageIndex[url] {
                browserViewModel.images[index].cameraRawSettings = cameraRaw
                browserViewModel.images[index].hasDevelopEdits = true
                if includeCrop, cameraRaw.crop?.isEffectiveCrop == true {
                    browserViewModel.images[index].hasCropEdits = true
                }
                browserViewModel.thumbnailService.invalidateEditedThumbnail(for: url)
                browserViewModel.fullScreenImageCache.invalidateEditedImage(for: url)
                editedURLsThisSession.insert(url)
            }
        }

        // Write camera raw settings to XMP in the image files
        let targetURLs = Array(urls)
        Task {
            // Simple crs scalar fields via the canonical serializer (ACR-style signed
            // ints, +exposure) — shared with the export engine and MetadataViewModel so
            // the three write paths can't drift. Crop is written separately below
            // (merge-style, per aspect group), so serialize a crop-less copy and drop the
            // empty crop keys it emits; the per-group crop handling adds them back.
            var bare = cameraRaw
            bare.crop = nil
            var fields = bare.developWriteFields()
            for key in [MetadataFieldKey.crsCropTop, .crsCropLeft, .crsCropBottom,
                        .crsCropRight, .crsCropAngle, .crsHasCrop,
                        .crsCropConstrainToWarp, .crsCropConstrainToUnitSquare] {
                fields.removeValue(forKey: key)
            }

            func cropFields(for crop: CameraRawCrop) -> [MetadataFieldKey: String] {
                [
                    .crsCropTop: crop.top.map { String(format: "%.6f", $0) } ?? "",
                    .crsCropLeft: crop.left.map { String(format: "%.6f", $0) } ?? "",
                    .crsCropBottom: crop.bottom.map { String(format: "%.6f", $0) } ?? "",
                    .crsCropRight: crop.right.map { String(format: "%.6f", $0) } ?? "",
                    .crsCropAngle: crop.angle.map { String(format: "%.6f", $0) } ?? "",
                    .crsHasCrop: "True",
                ]
            }
            let crop = (cameraRaw.crop?.isEmpty == false) ? cameraRaw.crop : nil
            let cropIsAngled = abs(crop?.angle ?? 0) > 0.0001
            if let crop, !cropIsAngled {
                fields.merge(cropFields(for: crop)) { _, new in new }
            }

            // Carry tone curve and masks too — a paste without them leaves the
            // targets rendering differently from the source. Masks only when the
            // source has some (merge-style, no replaceCameraRawBlock): pasting
            // from a mask-less image must not strip the targets' masks or other
            // settings the paste doesn't carry.
            let structuredData = StructuredWriteData(
                toneCurve: cameraRaw.toneCurve,
                masks: (cameraRaw.localAdjustments?.isEmpty == false) ? cameraRaw.localAdjustments : nil,
                watermarkLayers: (cameraRaw.watermarkLayers?.isEmpty == false) ? cameraRaw.watermarkLayers : nil,
                hslAdjustments: (cameraRaw.hslAdjustments?.isEmpty == false) ? cameraRaw.hslAdjustments : nil,
                layerOrder: cameraRaw.layerOrder,
                anonymizer: (cameraRaw.anonymizer?.isEmpty == false) ? cameraRaw.anonymizer : nil
            )

            do {
                if let crop, cropIsAngled {
                    // crs crop fields use Adobe's un-rotated-frame corner encoding,
                    // which depends on each target's pixel aspect — encode per
                    // aspect group instead of one shared field set.
                    var aspectGroups: [Double?: [URL]] = [:]
                    for url in targetURLs {
                        aspectGroups[ImagePixelAspect.aspect(at: url), default: []].append(url)
                    }
                    for (aspect, urls) in aspectGroups {
                        var groupFields = fields
                        groupFields.merge(cropFields(for: crop.encodedForACR(aspect: aspect))) { _, new in new }
                        try await browserViewModel.writeEngine.writeFields(
                            groupFields, to: urls, structuredData: structuredData
                        )
                    }
                } else {
                    try await browserViewModel.writeEngine.writeFields(
                        fields, to: targetURLs, structuredData: structuredData
                    )
                }
            } catch {
                Logger(subsystem: "com.aagedal.photo-agent", category: "EditWorkspaceView")
                    .error("Failed to paste camera raw to multiple images: \(error.localizedDescription)")
            }
        }

        // Reload the currently displayed image's metadata if it was in the paste set
        if let currentURL = selectedImageURL, urls.contains(currentURL) {
            metadataViewModel.loadMetadata(for: browserViewModel.selectedImages, folderURL: folderURL)
            editLog.info("[\(selectedImageURL?.lastPathComponent ?? "nil")] loadSelectedImagePreview triggered by: pasteCameraRaw")
            loadSelectedImagePreview()
        }

        onPendingStatusChanged?()
    }

    private func showCopyPasteFeedback(_ message: String) {
        copyPasteFeedback = message
        Task {
            try? await Task.sleep(for: .seconds(1))
            copyPasteFeedback = nil
        }
    }

    private func isTextFieldActive() -> Bool {
        guard let window = NSApp.keyWindow else { return false }
        if let responder = window.firstResponder {
            return responder is NSText || responder is NSTextView
        }
        return false
    }

    private func resetCropZoom() {
        cropSession.resetPreviewZoom()
    }

    // MARK: - Edit Zoom / Pan

    private struct EditCropViewport {
        var origin: SIMD2<Float>
        var size: SIMD2<Float>
    }

    /// Image dimensions from the Metal source texture (resolution-stable across Phase 1→2).
    /// Falls back to sourceCIImage/sourceImage for initial display before texture upload.
    private var metalImageSize: CGSize? {
        metalPipeline?.sourceTextureSize ?? sourceCIImage?.extent.size ?? sourceImage?.size
    }

    /// Current viewport origin for the Metal shader. Recomputed from zoom/offset state.
    private var currentViewportOrigin: SIMD2<Float> {
        guard let imageSize = metalImageSize else { return .zero }
        let containerSize = previewPaneFrame.size
        guard containerSize.width > 0, containerSize.height > 0,
              imageSize.width > 0, imageSize.height > 0 else { return .zero }

        let imageAspect = imageSize.width / imageSize.height
        let containerAspect = containerSize.width / containerSize.height

        let vpW: CGFloat
        let vpH: CGFloat
        if containerAspect > imageAspect {
            vpH = 1.0 / editZoomScale
            vpW = (1.0 / editZoomScale) * (containerAspect / imageAspect)
        } else {
            vpW = 1.0 / editZoomScale
            vpH = (1.0 / editZoomScale) * (imageAspect / containerAspect)
        }

        let fittedScale = min(containerSize.width / imageSize.width,
                              containerSize.height / imageSize.height)
        let fittedWidth = imageSize.width * fittedScale
        let fittedHeight = imageSize.height * fittedScale

        let offsetNormX = editOffset.width / (fittedWidth * editZoomScale)
        let offsetNormY = editOffset.height / (fittedHeight * editZoomScale)

        return SIMD2<Float>(Float(0.5 - offsetNormX - vpW / 2),
                            Float(0.5 - offsetNormY - vpH / 2))
    }

    /// Current viewport size for the Metal shader.
    private var currentViewportSize: SIMD2<Float> {
        guard let imageSize = metalImageSize else { return SIMD2<Float>(1, 1) }
        let containerSize = previewPaneFrame.size
        guard containerSize.width > 0, containerSize.height > 0,
              imageSize.width > 0, imageSize.height > 0 else { return SIMD2<Float>(1, 1) }

        let imageAspect = imageSize.width / imageSize.height
        let containerAspect = containerSize.width / containerSize.height

        if containerAspect > imageAspect {
            return SIMD2<Float>(Float((1.0 / editZoomScale) * (containerAspect / imageAspect)),
                                Float(1.0 / editZoomScale))
        } else {
            return SIMD2<Float>(Float(1.0 / editZoomScale),
                                Float((1.0 / editZoomScale) * (imageAspect / containerAspect)))
        }
    }

    private func editCropViewport(in containerSize: CGSize, imageSize: CGSize) -> EditCropViewport {
        guard containerSize.width > 0, containerSize.height > 0,
              imageSize.width > 0, imageSize.height > 0 else {
            return EditCropViewport(origin: .zero, size: SIMD2<Float>(1, 1))
        }

        let crop = displayCrop
        let imgW = Double(imageSize.width)
        let imgH = Double(imageSize.height)
        let actualW = max(crop.width, 0.0001) * imgW
        let actualH = max(crop.height, 0.0001) * imgH
        let centerX = crop.centerX
        let centerY = crop.centerY

        let handlePadding = EditCropPreviewFraming.handlePadding(isCropToolActive: false)
        let availW = max(Double(containerSize.width - handlePadding * 2), 1)
        let availH = max(Double(containerSize.height - handlePadding * 2), 1)
        let fitScale = min(availW / max(actualW, 1), availH / max(actualH, 1)) * max(Double(editZoomScale), 0.0001)
        guard fitScale > 0 else {
            return EditCropViewport(origin: .zero, size: SIMD2<Float>(1, 1))
        }

        let vpW = Double(containerSize.width) / fitScale / imgW
        let vpH = Double(containerSize.height) / fitScale / imgH

        let radians = displayCropAngle * .pi / 180.0
        let offsetPxX = Double(editOffset.width) / fitScale
        let offsetPxY = Double(editOffset.height) / fitScale
        let cosA = cos(radians)
        let sinA = sin(radians)
        let rotatedOffsetX = offsetPxX * cosA - offsetPxY * sinA
        let rotatedOffsetY = offsetPxX * sinA + offsetPxY * cosA
        let viewportCenterX = centerX - rotatedOffsetX / imgW
        let viewportCenterY = centerY - rotatedOffsetY / imgH

        return EditCropViewport(
            origin: SIMD2<Float>(Float(viewportCenterX - vpW / 2), Float(viewportCenterY - vpH / 2)),
            size: SIMD2<Float>(Float(vpW), Float(vpH))
        )
    }

    /// Sync the current zoom/pan state to the Metal pipeline's viewport parameters.
    /// Crop editing still uses a source-aspect MTKView and identity viewport, while
    /// confirmed crops render through a Metal crop viewport so high zoom/pan stays stable.
    private func syncViewportToMetal() {
        if showCropControls, !isShowingBefore {
            // Crop editing path: frame matches source aspect → identity viewport (stretch-to-fill)
            metalPipeline?.updateViewport(
                zoomScale: 1.0,
                offset: .zero,
                containerSize: CGSize(width: 100, height: 100),
                imageSize: CGSize(width: 100, height: 100)
            )
            metalCoordinator.viewportOrigin = .zero
            metalCoordinator.viewportSize = SIMD2<Float>(1, 1)
            metalCoordinator.requestRedraw()
            return
        }

        if isCropEnabled, !isShowingBefore {
            let imageSize = metalImageSize ?? currentImageSize ?? CGSize(width: 1, height: 1)
            let crop = displayCrop
            metalPipeline?.updateCropViewport(
                containerSize: previewPaneFrame.size,
                imageSize: imageSize,
                cropLeft: crop.left,
                cropTop: crop.top,
                cropRight: crop.right,
                cropBottom: crop.bottom,
                angleDegrees: displayCropAngle,
                zoomScale: editZoomScale,
                offset: editOffset,
                handlePadding: EditCropPreviewFraming.handlePadding(isCropToolActive: false)
            )
            let viewport = editCropViewport(in: previewPaneFrame.size, imageSize: imageSize)
            metalCoordinator.viewportOrigin = viewport.origin
            metalCoordinator.viewportSize = viewport.size
            metalCoordinator.requestRedraw()
            return
        }

        guard let imageSize = metalImageSize else { return }
        metalPipeline?.updateViewport(
            zoomScale: editZoomScale,
            offset: editOffset,
            containerSize: previewPaneFrame.size,
            imageSize: imageSize
        )
        // Also sync to the CIImage fallback path (used for "before" toggle)
        metalCoordinator.viewportOrigin = currentViewportOrigin
        metalCoordinator.viewportSize = currentViewportSize
        metalCoordinator.requestRedraw()
    }

    private func resetEditZoom() {
        previewNavigation.reset()
        syncViewportToMetal()
    }

    private func handleEditScrollZoom(delta: CGFloat, event: NSEvent) {
        let zoomFactor = 1.0 + (delta * 0.01)
        let oldScale = editZoomScale
        let newScale = EditZoomBehavior.clampedScale(oldScale * zoomFactor)
        guard newScale != oldScale else { return }

        applyEditZoom(
            oldScale: oldScale,
            newScale: newScale,
            cursorFromCenter: editCursorFromCenter(event: event)
        )
    }

    /// Applies an edit zoom while preserving the source point beneath the cursor. Both scroll
    /// zoom and the Z-key 1:1 toggle use this path so their anchoring behavior stays identical.
    private func applyEditZoom(oldScale: CGFloat, newScale: CGFloat, cursorFromCenter: CGSize) {
        if isCropEnabled, !showCropControls, !isShowingBefore {
            handleCroppedEditZoom(
                oldScale: oldScale,
                newScale: newScale,
                cursorFromCenter: cursorFromCenter
            )
            return
        }

        if newScale <= 1.0 {
            previewNavigation.applyZoom(scale: newScale)
            syncViewportToMetal()
            return
        }

        // Cursor-anchored zoom in viewport UV space: compute which UV coordinate
        // is under the cursor, then solve for the offset that keeps it there
        // after the zoom change.
        let containerSize = previewPaneFrame.size
        guard containerSize.width > 0, containerSize.height > 0,
              let imageSize = metalImageSize else {
            previewNavigation.applyZoom(scale: newScale)
            syncViewportToMetal()
            return
        }

        let screenNormX = 0.5 + cursorFromCenter.width / containerSize.width
        let screenNormY = 0.5 + cursorFromCenter.height / containerSize.height

        // Current viewport: UV at cursor
        let vpOrigin = currentViewportOrigin
        let vpSize = currentViewportSize
        let uvX = Double(vpOrigin.x) + screenNormX * Double(vpSize.x)
        let uvY = Double(vpOrigin.y) + screenNormY * Double(vpSize.y)

        // New viewport size at newScale
        let imageAspect = imageSize.width / imageSize.height
        let containerAspect = containerSize.width / containerSize.height
        let newVpW: Double
        let newVpH: Double
        if containerAspect > imageAspect {
            newVpH = 1.0 / newScale
            newVpW = (1.0 / newScale) * (containerAspect / imageAspect)
        } else {
            newVpW = 1.0 / newScale
            newVpH = (1.0 / newScale) * (imageAspect / containerAspect)
        }

        // Solve for new offset: place uvX at screenNormX in new viewport
        // newVpOrigin = uv - screenNorm * newVpSize
        // vpOrigin = 0.5 - offNorm - vpSize/2, so offNorm = 0.5 - vpSize/2 - vpOrigin
        let newVpOriginX = uvX - screenNormX * newVpW
        let newVpOriginY = uvY - screenNormY * newVpH

        let fittedScale = min(containerSize.width / imageSize.width,
                              containerSize.height / imageSize.height)
        let fittedWidth = imageSize.width * fittedScale
        let fittedHeight = imageSize.height * fittedScale

        let offNormX = 0.5 - newVpW / 2 - newVpOriginX
        let offNormY = 0.5 - newVpH / 2 - newVpOriginY
        let newOffset = CGSize(
            width: offNormX * fittedWidth * newScale,
            height: offNormY * fittedHeight * newScale
        )

        // Constrain to valid bounds
        let scaledWidth = fittedWidth * newScale
        let scaledHeight = fittedHeight * newScale
        let maxOffsetX = max(0, (scaledWidth - containerSize.width) / 2)
        let maxOffsetY = max(0, (scaledHeight - containerSize.height) / 2)
        previewNavigation.applyZoom(scale: newScale, anchoredOffset: newOffset)
        previewNavigation.constrainOffset(
            maximum: CGSize(width: maxOffsetX, height: maxOffsetY)
        )

        syncViewportToMetal()
    }

    private func handleCroppedEditZoom(
        oldScale: CGFloat,
        newScale: CGFloat,
        cursorFromCenter cursor: CGSize
    ) {
        let containerSize = previewPaneFrame.size
        guard containerSize.width > 0, containerSize.height > 0 else {
            previewNavigation.applyZoom(scale: newScale)
            syncViewportToMetal()
            return
        }

        if newScale <= 1.0 {
            previewNavigation.applyZoom(scale: newScale)
            syncViewportToMetal()
            return
        }

        let zoomRatio = newScale / oldScale
        let anchoredOffset = CGSize(
            width: cursor.width - (cursor.width - editOffset.width) * zoomRatio,
            height: cursor.height - (cursor.height - editOffset.height) * zoomRatio
        )

        previewNavigation.applyZoom(scale: newScale, anchoredOffset: anchoredOffset)
        constrainEditOffset(in: containerSize, imageSize: containerSize)
    }

    /// Compute cursor position relative to preview pane center (in SwiftUI coordinates).
    private func editCursorFromCenter(event: NSEvent) -> CGSize {
        guard let contentHeight = NSApp.keyWindow?.contentView?.bounds.height else {
            return .zero
        }
        let windowLoc = event.locationInWindow
        // Convert from NSView coords (Y-up) to SwiftUI coords (Y-down)
        let swiftUIX = windowLoc.x
        let swiftUIY = contentHeight - windowLoc.y
        return CGSize(
            width: swiftUIX - previewPaneFrame.midX,
            height: swiftUIY - previewPaneFrame.midY
        )
    }

    /// Key events do not reliably carry the pointer location. Match the full-screen viewer by
    /// reading the live screen-space mouse location and converting it into preview coordinates.
    private func currentEditCursorFromCenter() -> CGSize {
        guard let window = NSApp.keyWindow,
              let contentHeight = window.contentView?.bounds.height else {
            return .zero
        }
        let windowLocation = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let swiftUIY = contentHeight - windowLocation.y
        return CGSize(
            width: windowLocation.x - previewPaneFrame.midX,
            height: swiftUIY - previewPaneFrame.midY
        )
    }

    /// Center for a keyboard-created radial mask. This uses the same pane-to-viewport mapping
    /// supplied to the mask overlay, so it remains correct through fitted, zoomed, panned, and
    /// cropped previews. Crop-edit mode uses a differently framed/rotated view and keeps the old
    /// centered fallback until that tool is dismissed.
    private func maskCenterUnderCursor() -> CGPoint? {
        guard isCursorOverPreview, !showCropControls else { return nil }
        let paneSize = previewPaneFrame.size
        let cursor = currentEditCursorFromCenter()
        let panePoint = CGPoint(
            x: paneSize.width / 2 + cursor.width,
            y: paneSize.height / 2 + cursor.height
        )
        let viewport: (origin: SIMD2<Float>, size: SIMD2<Float>)
        if isCropEnabled, !isShowingBefore {
            let imageSize = metalImageSize ?? currentImageSize ?? CGSize(width: 1, height: 1)
            let cropViewport = editCropViewport(in: paneSize, imageSize: imageSize)
            viewport = (cropViewport.origin, cropViewport.size)
        } else {
            viewport = (currentViewportOrigin, currentViewportSize)
        }
        return EditPreviewCoordinateMapper.displayUV(
            forPanePoint: panePoint,
            paneSize: paneSize,
            viewportOrigin: viewport.origin,
            viewportSize: viewport.size
        )
    }

    private func editPanGesture(in containerSize: CGSize, imageSize: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard previewNavigation.updatePan(translation: value.translation) else { return }
                syncViewportToMetal()
            }
            .onEnded { _ in
                guard editZoomScale > 1.0 else {
                    previewNavigation.recenter()
                    syncViewportToMetal()
                    return
                }
                constrainEditOffset(in: containerSize, imageSize: imageSize)
            }
    }

    /// Dedicated pan gesture used by the hold-Space hand-tool surface. It mirrors normal
    /// preview panning, but sits above every editing overlay and provides hand cursor feedback.
    private func editHandPanGesture(in containerSize: CGSize, imageSize: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard previewNavigation.updatePan(translation: value.translation) else { return }
                NSCursor.closedHand.set()
                syncViewportToMetal()
            }
            .onEnded { _ in
                guard editZoomScale > 1.0 else {
                    previewNavigation.recenter()
                    syncViewportToMetal()
                    NSCursor.openHand.set()
                    return
                }
                constrainEditOffset(in: containerSize, imageSize: imageSize)
                if isSpaceHandToolActive {
                    NSCursor.openHand.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
    }

    private func constrainEditOffset(in containerSize: CGSize, imageSize: CGSize) {
        let scaledWidth: CGFloat
        let scaledHeight: CGFloat
        if isCropEnabled, !showCropControls, !isShowingBefore {
            let imgSize = currentImageSize ?? metalImageSize ?? imageSize
            let imageRect = cropFittedImageRect(
                in: containerSize,
                imageSize: imgSize,
                crop: displayCrop,
                angleDegrees: displayCropAngle,
                zoom: editZoomScale,
                handlePadding: EditCropPreviewFraming.handlePadding(isCropToolActive: false)
            )
            let cropRect = cropViewRect(crop: displayCrop, angleDegrees: displayCropAngle, imageRect: imageRect)
            scaledWidth = cropRect.width
            scaledHeight = cropRect.height
        } else {
            let imgSize = metalImageSize ?? imageSize
            let fittedScale = min(containerSize.width / imgSize.width,
                                  containerSize.height / imgSize.height)
            scaledWidth = imgSize.width * fittedScale * editZoomScale
            scaledHeight = imgSize.height * fittedScale * editZoomScale
        }
        let maxOffsetX = max(0, (scaledWidth - containerSize.width) / 2)
        let maxOffsetY = max(0, (scaledHeight - containerSize.height) / 2)
        previewNavigation.constrainOffset(
            maximum: CGSize(width: maxOffsetX, height: maxOffsetY)
        )
        syncViewportToMetal()
    }

    private func toggleEditZoom() {
        let containerSize = previewPaneFrame.size
        guard containerSize.width > 0, containerSize.height > 0 else { return }

        let zoom100 = calculateEditZoomTo100(in: containerSize)
        let isAt100 = abs(editZoomScale - zoom100) < 0.01

        if isAt100 || editZoomScale > 1.0 {
            // Return to fit
            resetEditZoom()
        } else {
            // Zoom to 100% (clamped to max), preserving the point beneath the cursor.
            applyEditZoom(
                oldScale: editZoomScale,
                newScale: min(zoom100, EditZoomBehavior.maximumScale),
                cursorFromCenter: isCursorOverPreview ? currentEditCursorFromCenter() : .zero
            )
        }
    }

    private func calculateEditZoomTo100(in containerSize: CGSize) -> CGFloat {
        let backingScale = NSScreen.main?.backingScaleFactor ?? 2.0
        // Use source texture dimensions for accurate 1:1 pixel mapping
        let sourceWidth = CGFloat(metalPipeline?.sourceTextureSize?.width ?? currentImageSize?.width ?? 1)
        let sourceHeight = CGFloat(metalPipeline?.sourceTextureSize?.height ?? currentImageSize?.height ?? 1)
        let fittedScale = min(containerSize.width / sourceWidth, containerSize.height / sourceHeight)
        let fittedWidth = sourceWidth * fittedScale
        guard fittedWidth > 0 else { return 1.0 }
        // At zoom100, 1 source pixel = 1 physical screen pixel
        return sourceWidth / (fittedWidth * backingScale)
    }

    // MARK: - Key Event Handling

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        let chars = event.charactersIgnoringModifiers ?? ""
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isKeyDown = event.type == .keyDown
        let isKeyUp = event.type == .keyUp

        // Escape
        if event.keyCode == 53, isKeyDown {
            guard !isTextFieldActive() else { return event }
            if isSelectingAIMask {
                cancelAIMaskSelection()
                return nil
            }
            if showCropControls {
                toggleCropControls()
                return nil
            }
            requestEditWorkspaceExit()
            return nil
        }

        // Hold Space to temporarily override every image-interaction tool with a hand tool.
        // Keep text entry and the dedicated crop editor untouched; normal Develop zoom/pan
        // includes brush, ellipse, watermark, and white-balance overlays.
        if event.keyCode == 49 {
            if isKeyUp {
                guard isSpaceHandToolActive else { return event }
                isSpaceHandToolActive = false
                NSCursor.arrow.set()
                return nil
            }
            guard isKeyDown, !isTextFieldActive(), !showCropControls else { return event }
            isSpaceHandToolActive = true
            if isCursorOverPreview { NSCursor.openHand.set() }
            return nil
        }

        // M key — hold to show before, release to hide
        if chars == "m" {
            if isKeyUp {
                transientPreview.endBeforeComparison()
                return nil
            }
            guard !isTextFieldActive(), canEditSingleImage else { return event }
            transientPreview.beginBeforeComparison()
            return nil
        }

        // Release whichever D comparison began even if Command was released before D. The
        // coordinator retains the active mode, so key-up does not depend on modifier ordering.
        if chars == "d", isKeyUp {
            if transientPreview.endLayerMute() {
                renderPreview()
                return nil
            }
            if isMutingDevelop {
                transientPreview.endDevelopMute()
                return nil
            }
            return event
        }

        // Cmd+D — hold to mute only the current layer (global or selected mask)
        if chars == "d" && modifiers.contains(.command) {
            guard !isTextFieldActive(), canEditSingleImage else { return nil }
            if let idx = selectedMaskIndex {
                // Mute selected mask
                guard let masks = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments,
                      idx < masks.count, masks[idx].enabled else { return nil }
                if transientPreview.beginLayerMute(maskIndex: idx) {
                    renderPreview()
                }
            } else {
                // Mute global adjustments — send masks-only settings to pipeline
                if transientPreview.beginLayerMute(maskIndex: nil) {
                    renderPreview()
                }
            }
            return nil
        }

        // D key — hold to disable develop adjustments (keep crop visible)
        if chars == "d" && modifiers.isDisjoint(with: [.command, .option, .control]) {
            guard !isTextFieldActive(), canEditSingleImage else { return event }
            transientPreview.beginDevelopMute()
            return nil
        }

        // All remaining handlers are key-down only
        guard isKeyDown else { return event }

        // Control+Option+Delete removes the selected local layer or resets Global without
        // overriding the system Close Window command. Ignore repeat so holding Delete cannot
        // remove a run of adjacent layers.
        if [51, 117].contains(Int(event.keyCode)),
           modifiers.contains([.control, .option]),
           modifiers.isDisjoint(with: [.command, .shift]) {
            guard !event.isARepeat else { return nil }
            if canEditSingleImage {
                removeOrResetSelectedEditLayer()
            }
            return nil
        }

        guard !isTextFieldActive() else { return event }

        if !browserViewModel.selectedImageIDs.isEmpty,
           let key = chars.first,
           let action = KeyboardShortcutRouter.resolve(
            KeyboardShortcutRouteInput(
                key: String(key),
                modifiers: KeyboardShortcutModifiers(event.modifierFlags),
                textEditorOwnsInput: isTextFieldActive(),
                imeHasMarkedText: keyboardTextInputState(in: event.window).imeHasMarkedText,
                isRepeat: event.isARepeat
            ),
            profile: KeyboardShortcutProfileRegistry.shared.selectedProfile
           ) {
            switch action {
            case let .rating(value):
                if let rating = StarRating(rawValue: value) {
                    browserViewModel.setRating(rating)
                }
            case let .colorLabel(index):
                if let label = ColorLabel.fromShortcutIndex(index) {
                    browserViewModel.setLabel(label)
                }
            }
            return nil
        }

        // Arrow keys
        if event.keyCode == 123 { // left arrow
            requestAdjacentDevelopImage(forward: false)
            return nil
        }
        if event.keyCode == 124 { // right arrow
            requestAdjacentDevelopImage(forward: true)
            return nil
        }

        // Cmd+C — copy develop settings
        if chars == "c" && modifiers.contains(.command) {
            guard canEditSingleImage else { return event }
            browserViewModel.copiedCameraRawSettings = metadataViewModel.editingMetadata.cameraRaw
            showCopyPasteFeedback("Copied")
            return nil
        }

        // C — toggle crop controls
        if chars == "c" && modifiers.isDisjoint(with: [.command, .option, .control]) {
            guard canEditSingleImage else { return event }
            toggleCropControls()
            return nil
        }

        // J — add a new ellipse (radial) mask. Bare-letter tool shortcut, matching the
        // Photoshop-style convention (the brush mask tool is bare "B", below);
        // Cmd+J still works too (menu item).
        if chars == "j" && modifiers.isDisjoint(with: [.command, .option, .control]) {
            guard canEditSingleImage else { return event }
            addNewMask(center: maskCenterUnderCursor())
            return nil
        }

        // B — toggle the freeform brush paint tool (Photoshop convention). Turning it on
        // deselects the WB eyedropper so the two drag-driven tools don't fight over the mouse.
        if chars == "b" && modifiers.isDisjoint(with: [.command, .option, .control]) {
            guard canEditSingleImage else { return event }
            maskInteraction.toggleBrushPainting()
            if isBrushPainting { isPickingWhiteBalance = false }
            syncMaskOverlayTarget()
            return nil
        }

        // X — swap the brush between Add and Erase (Photoshop swaps FG/BG on X). Only meaningful
        // in a brush context, so pass the event through otherwise.
        if chars == "x" && modifiers.isDisjoint(with: [.command, .option, .control]) {
            guard canEditSingleImage, isBrushPainting || selectedMaskIsBrush else { return event }
            maskInteraction.brushErase.toggle()
            return nil
        }

        // Cmd+V / Cmd+Shift+V — paste develop settings
        if chars == "v" && modifiers.contains(.command) {
            guard let copied = browserViewModel.copiedCameraRawSettings else { return event }
            let withCrop = modifiers.contains(.shift)
            let selectedURLs = browserViewModel.selectedImageIDs
            guard !selectedURLs.isEmpty else { return event }

            if selectedURLs.count == 1 {
                pasteCameraRawSettings(copied, includeCrop: withCrop)
                showCopyPasteFeedback(withCrop ? "Pasted (with crop)" : "Pasted")
            } else {
                pasteToMultipleImages(copied, urls: selectedURLs, includeCrop: withCrop)
                showCopyPasteFeedback("Pasted to \(selectedURLs.count) images")
            }
            return nil
        }

        // Option+V — paste develop settings including crop (crop is opt-in,
        // matching Adobe's copy-dialog default of leaving crop unchecked).
        // Exclude Cmd+Option+V, which is reserved for Paste IPTC Metadata.
        if chars == "v" && modifiers.contains(.option) && !modifiers.contains(.command) {
            guard let copied = browserViewModel.copiedCameraRawSettings else { return event }
            let selectedURLs = browserViewModel.selectedImageIDs
            guard !selectedURLs.isEmpty else { return event }

            if selectedURLs.count == 1 {
                pasteCameraRawSettings(copied, includeCrop: true)
                showCopyPasteFeedback("Pasted (with crop)")
            } else {
                pasteToMultipleImages(copied, urls: selectedURLs, includeCrop: true)
                showCopyPasteFeedback("Pasted to \(selectedURLs.count) images (with crop)")
            }
            return nil
        }

        // Cmd+Z / Cmd+Shift+Z — undo/redo
        if chars == "z" && modifiers.contains(.command) {
            if modifiers.contains(.shift) {
                editUndoManager.redo()
            } else {
                editUndoManager.undo()
            }
            return nil
        }

        // Z key — toggle zoom fit / 100%
        if chars == "z" && modifiers.isDisjoint(with: [.command, .option, .control]) {
            guard !showCropControls else { return event }
            toggleEditZoom()
            return nil
        }

        return event
    }
}

private struct EditWorkspaceExportFailureAlertModifier: ViewModifier {
    @Binding var saveError: String?

    func body(content: Content) -> some View {
        content.alert("Export Failed", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "The export could not be completed.")
        }
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

/// Lightweight hidden view that observes format settings and HDR state,
/// updating the scope's display gamut. Extracted to avoid SwiftUI type-check
/// timeouts in EditWorkspaceView's large body.
private struct DisplayGamutObserver: View {
    let scopeViewModel: ScopeViewModel
    let settingsViewModel: SettingsViewModel
    let isHDR: Bool

    var body: some View {
        let gamut = isHDR ? settingsViewModel.exportColorGamutHDR : settingsViewModel.exportColorGamutSDR
        Color.clear
            .onChange(of: gamut) { _, newValue in
                scopeViewModel.displayGamut = newValue
            }
            .onChange(of: isHDR) { _, _ in
                scopeViewModel.displayGamut = isHDR
                    ? settingsViewModel.exportColorGamutHDR
                    : settingsViewModel.exportColorGamutSDR
            }
            .onAppear {
                scopeViewModel.displayGamut = gamut
            }
    }
}

/// Transparent gesture catcher for the white-balance eyedropper. A tap samples a small
/// spot; a drag sweeps a marquee whose area is averaged. Reports the chosen rectangle in
/// its own (preview-pane) coordinate space; the workspace maps that to source pixels.
private struct WhiteBalancePickOverlay: View {
    @Environment(\.suppressesEditCursorOverlays) private var suppressesCursorOverlays
    @Binding var marquee: CGRect?
    /// Synchronous averaged-colour probe (linear) for the rect — drives the debug readout.
    let probe: (CGRect) -> SIMD3<Float>?
    let onPick: (CGRect) -> Void
    @State private var start: CGPoint?
    @State private var cursor: CGPoint?
    @State private var readout: SIMD3<Float>?

    /// Below this drag distance (points) a gesture counts as a spot tap.
    private static let tapThreshold: CGFloat = 4
    /// Spot-tap sample box (points) centred on the tap.
    private static let spotSize: CGFloat = 9

    private func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private func spotRect(at p: CGPoint) -> CGRect {
        CGRect(x: p.x - Self.spotSize / 2, y: p.y - Self.spotSize / 2,
               width: Self.spotSize, height: Self.spotSize)
    }

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))   // effectively invisible, still hit-testable
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if start == nil { start = value.startLocation }
                        let r = rect(from: start ?? value.startLocation, to: value.location)
                        marquee = r
                        cursor = value.location
                        let big = r.width > Self.spotSize || r.height > Self.spotSize
                        readout = probe(big ? r : spotRect(at: value.location))
                    }
                    .onEnded { value in
                        let s = start ?? value.startLocation
                        let distance = hypot(value.location.x - s.x, value.location.y - s.y)
                        onPick(distance > Self.tapThreshold ? rect(from: s, to: value.location)
                                                            : spotRect(at: value.location))
                        marquee = nil
                        start = nil
                    }
            )
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let p):
                    if marquee == nil {
                        cursor = p
                        readout = probe(spotRect(at: p))
                    }
                case .ended:
                    if marquee == nil { cursor = nil; readout = nil }
                }
            }
            .overlay {
                if let m = marquee {
                    Rectangle()
                        .strokeBorder(Color.white, lineWidth: 1)
                        .background(Color.white.opacity(0.08))
                        .frame(width: m.width, height: m.height)
                        .position(x: m.midX, y: m.midY)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topLeading) {
                if !suppressesCursorOverlays, let cursor, let readout {
                    WhiteBalanceReadout(color: readout)
                        .allowsHitTesting(false)
                        .alignmentGuide(.leading) { _ in -(cursor.x + 16) }
                        .alignmentGuide(.top) { _ in -(cursor.y + 16) }
                }
            }
            // Crosshair cursor on top: a cursorUpdate tracking area re-asserts the cursor on
            // every mouse-move, so the Metal view's own tracking area can't reset it to the
            // arrow (a one-shot NSCursor.push does get overridden).
            .overlay {
                if !suppressesCursorOverlays {
                    CrosshairCursorView().allowsHitTesting(false)
                }
            }
            .onChange(of: suppressesCursorOverlays) { _, isSuppressed in
                if isSuppressed {
                    cursor = nil
                    readout = nil
                }
            }
    }
}

/// Transparent one-click surface for Vision person/object selection. The shared cursor view
/// wins cursor arbitration against the underlying Metal/AppKit preview.
private struct AIMaskPickOverlay: View {
    let isEnabled: Bool
    let onPick: (CGPoint) -> Void

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture()
                    .onEnded { value in
                        guard isEnabled else { return }
                        onPick(value.location)
                    }
            )
            .overlay {
                CrosshairCursorView().allowsHitTesting(false)
            }
    }
}

/// Debug HUD beside the eyedropper: the averaged linear-RGB sample fed to the solver, plus
/// its R/G and B/G ratios (which reveal a colour cast at a glance) and a colour swatch.
private struct WhiteBalanceReadout: View {
    let color: SIMD3<Float>

    private func clamp(_ v: Float) -> Double { Double(min(max(v, 0), 1)) }

    var body: some View {
        let g = max(color.y, 1e-6)
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(.sRGBLinear, red: clamp(color.x), green: clamp(color.y), blue: clamp(color.z)))
                .frame(width: 20, height: 20)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(.white.opacity(0.5), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 1) {
                Text(String(format: "lin %.3f %.3f %.3f", color.x, color.y, color.z))
                Text(String(format: "R/G %.2f   B/G %.2f", color.x / g, color.z / g))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .font(.system(size: 10, weight: .medium).monospaced())
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
        .foregroundStyle(.white)
        .fixedSize()
    }
}

/// Forces the crosshair cursor across its bounds via a `cursorUpdate` tracking area —
/// robust against sibling AppKit views that manage their own cursor.
private struct CrosshairCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { TrackingView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class TrackingView: NSView {
        private var area: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.activeInActiveApp, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect],
                owner: self, userInfo: nil
            )
            addTrackingArea(area)
            self.area = area
        }

        override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
        override func mouseEntered(with event: NSEvent) { NSCursor.crosshair.set() }
    }
}
