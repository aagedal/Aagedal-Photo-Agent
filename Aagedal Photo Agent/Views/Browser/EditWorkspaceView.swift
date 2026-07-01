import AppKit
import CoreImage
import os
import SwiftUI
import UniformTypeIdentifiers

nonisolated private let editLog = Logger(
    subsystem: "com.aagedal.photo-agent", category: "EditWorkspace"
)

struct EditWorkspaceView: View {
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
    @State private var previewImage: NSImage?
    @State private var previewTask: Task<Void, Never>?
    @State private var previewRenderTask: Task<Void, Never>?
    @State private var isLoadingPreview = false
    @State private var isDecodingFullResolution = false
    @State private var isSavingRenderedJPEG = false
    @State private var saveError: String?
    @State private var copyPasteFeedback: String?
    @State private var cropZoomScale: CGFloat = 1.0
    @State private var lastCropZoomScale: CGFloat = 1.0
    @State private var cropAspectRatio: CropAspectRatio = .original
    @State private var isCursorOverPreview = false
    @State private var scrollEventMonitor: Any?
    @State private var keyEventMonitor: Any?
    @State private var isShowingBefore = false
    @State private var isMutingDevelop = false
    @State private var isMutingSelectedMask = false
    @State private var isMutingGlobal = false
    @State private var isMutingColor = false
    @State private var isMutingExposure = false
    @State private var isMutingToneCurve = false
    @State private var isMutingHSL = false
    @State private var mutedMaskIndex: Int?
    @State private var showCropControls = false
    @State private var lockedCropImageRect: CGRect?
    @State private var dragCropAngle: Double?
    @State private var dragCropRegion: NormalizedCropRegion?
    @State private var editUndoManager = UndoManager()
    /// URLs whose develop settings actually changed during this edit session. On exit these are
    /// proactively re-rendered into the full-screen + thumbnail caches so the return to culling is
    /// instant and correct, rather than catching up reactively a beat later. Populated wherever
    /// edits are written back to `images[].cameraRawSettings`; consumed in `handleEditWorkspaceDisappear`.
    @State private var editedURLsThisSession: Set<URL> = []
    @State private var metalPipeline: MetalEditPipeline?
    @State private var metalCoordinator = MetalPreviewView.Coordinator()
    /// The selected node in the layer chain. `.global` shows the global adjustment sliders;
    /// `.mask(id)` shows that mask's sliders and overlay. Identity-based so it survives reorder.
    @State private var selectedLayer: LayerRef = .global
    /// The layer card currently being dragged for reorder, and the card it's hovering over.
    @State private var draggingLayer: LayerRef?
    @State private var dropTargetLayer: LayerRef?
    @State private var isDraggingMask = false
    @State private var dragMaskGeometry: EllipseMaskGeometry?
    @State private var scopeThrottleTask: Task<Void, Never>?
    @State private var lastScopeUpdateTime: ContinuousClock.Instant = .now
    @State private var editZoomScale: CGFloat = 1.0
    @State private var lastEditZoomScale: CGFloat = 1.0
    /// True once the Metal source texture has been upgraded from the screen-resolution
    /// Phase 2 decode to a full-sensor-resolution decode for pixel-peeping at high zoom.
    @State private var isEditFullResLoaded = false
    @State private var editFullResTask: Task<Void, Never>?
    @State private var editOffset: CGSize = .zero
    @State private var lastEditOffset: CGSize = .zero
    @State private var previewPaneFrame: CGRect = .zero
    @State private var isHoveringHDR = false
    @State private var asShotWhiteBalance: (temperature: Float, tint: Float)?
    /// White-balance eyedropper mode: when on, the preview shows a crosshair and a
    /// click (or drag-rectangle) sets the WB from the sampled area.
    @State private var isPickingWhiteBalance = false
    /// Live marquee rectangle (preview-pane coordinates) drawn while dragging a WB sample.
    @State private var wbPickDragRect: CGRect?

    // Freeform brush-paint tool (bare "B"). Settings are transient UI state describing what's
    // about to be painted — already-painted strokes keep whatever they were painted with.
    @State private var isBrushPainting = false
    @State private var brushRadius: Double = 0.04     // fraction of the long edge (BrushStroke.radius)
    @State private var brushHardness: Double = 0.5    // 0-1 dab CenterWeight
    @State private var brushFlow: Double = 0.8        // 0-1 dab flow
    @State private var brushErase = false             // subtract from the mask instead of adding
    @FocusState private var isWorkspaceFocused: Bool

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

    private var canEditSingleImage: Bool {
        metadataViewModel.selectedCount == 1 && !metadataViewModel.isBatchEdit
    }

    private var displayImage: NSImage? {
        isShowingBefore ? sourceImage : previewImage
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
            || cameraRaw.toneCurve != nil
            || !(cameraRaw.localAdjustments?.isEmpty ?? true)
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                previewPane
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
                if let angle = dragCropAngle {
                    updateCropAngle(angle, commit: false)
                }
                dragCropAngle = nil
                dragCropRegion = nil
                metalCoordinator.stopContinuousRendering()
                cleanFeedController.setFeedContinuousRendering(false)
                scopeThrottleTask?.cancel()
                scopeThrottleTask = nil
                renderPreview()
            }
        }
        .onChange(of: selectedImage?.exifOrientation) { oldVal, newVal in
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
            // Clear Metal overlay — the AppKit MaskOverlayNSView handles
            // static display with interactive handles. Metal overlay is only used
            // during active mask drags for real-time feedback.
            metalPipeline?.updateOverlayParams(geometry: nil, visible: false)
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
        .onReceive(NotificationCenter.default.publisher(for: .addNewMask)) { _ in
            guard canEditSingleImage else { return }
            addNewMask()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleHDR)) { _ in
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
        .alert("Export Failed", isPresented: saveErrorPresented) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            if let error = saveError {
                Text(error)
            }
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
                            zoom: zoom
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
                                        // Local @State only — bypass ViewModel during drag
                                        // to avoid expensive body re-evaluation cascade
                                        dragCropRegion = newCrop
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
                                        dragCropAngle = clampedAngle
                                        dragCropRegion = fitted
                                    },
                                    onCommit: {
                                        // Commit accumulated drag state to ViewModel
                                        if let region = dragCropRegion {
                                            updateCrop(region, commit: false)
                                        }
                                        if let angle = dragCropAngle {
                                            updateCropAngle(angle, commit: false)
                                        }
                                        dragCropRegion = nil
                                        dragCropAngle = nil
                                        lockedCropImageRect = nil
                                        commitEditAdjustments()
                                    },
                                    onAspectRatioOverride: { newRatio in
                                        cropAspectRatio = newRatio
                                    }
                                )
                            }
                        } else {
                            // Crop applied, normal editing: support zoom/pan
                            ZStack {
                                MetalPreviewView(
                                    ciImage: displayCIImage,
                                    isHDR: isHDREnabled && !isShowingBefore,
                                    metalPipeline: metalPipeline,
                                    useComputeShader: !isShowingBefore && metalPipeline?.hasSourceTexture == true,

                                    coordinator: metalCoordinator
                                )
                                    .frame(width: imageRect.width, height: imageRect.height)
                                    .rotationEffect(.degrees(-displayCropAngle))
                                    .position(x: imageRect.midX, y: imageRect.midY)

                                // Black out area outside crop
                                let cropRect = cropViewRect(crop: displayCrop, angleDegrees: displayCropAngle, imageRect: imageRect)
                                Path { path in
                                    path.addRect(CGRect(origin: .zero, size: geometry.size))
                                    path.addRect(cropRect)
                                }
                                .fill(Self.previewBackground, style: FillStyle(eoFill: true))
                                .allowsHitTesting(false)

                                // Ellipse mask overlay (crop-applied path) — ellipse masks only,
                                // suppressed while the brush tool owns the mouse.
                                if let maskIdx = selectedMaskIndex,
                                   let masks = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments,
                                   maskIdx < masks.count,
                                   masks[maskIdx].brush == nil,
                                   !isBrushPainting,
                                   !isShowingBefore {
                                    let cropVpOrigin = SIMD2<Float>(
                                        Float(-imageRect.minX / imageRect.width),
                                        Float(-imageRect.minY / imageRect.height)
                                    )
                                    let cropVpSize = SIMD2<Float>(
                                        Float(geometry.size.width / imageRect.width),
                                        Float(geometry.size.height / imageRect.height)
                                    )
                                    MaskOverlayRepresentable(
                                        viewportOrigin: cropVpOrigin,
                                        viewportSize: cropVpSize,
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
                                }

                                // White-balance eyedropper over the crop-framed preview.
                                if isPickingWhiteBalance, !isShowingBefore {
                                    let cropVpOrigin = SIMD2<Float>(
                                        Float(-imageRect.minX / imageRect.width),
                                        Float(-imageRect.minY / imageRect.height)
                                    )
                                    let cropVpSize = SIMD2<Float>(
                                        Float(geometry.size.width / imageRect.width),
                                        Float(geometry.size.height / imageRect.height)
                                    )
                                    WhiteBalancePickOverlay(
                                        marquee: $wbPickDragRect,
                                        probe: { rect in
                                            probeLinearRGB(
                                                forPaneRect: rect, paneSize: geometry.size,
                                                viewportOrigin: cropVpOrigin, viewportSize: cropVpSize
                                            )
                                        },
                                        onPick: { rect in
                                            performWhiteBalancePick(
                                                inPaneRect: rect, paneSize: geometry.size,
                                                viewportOrigin: cropVpOrigin, viewportSize: cropVpSize
                                            )
                                        }
                                    )
                                    .frame(width: geometry.size.width, height: geometry.size.height)
                                }

                                // Freeform brush paint overlay (crop-applied path).
                                let brushVpOrigin = SIMD2<Float>(
                                    Float(-imageRect.minX / imageRect.width),
                                    Float(-imageRect.minY / imageRect.height)
                                )
                                let brushVpSize = SIMD2<Float>(
                                    Float(geometry.size.width / imageRect.width),
                                    Float(geometry.size.height / imageRect.height)
                                )
                                brushOverlay(viewportOrigin: brushVpOrigin, viewportSize: brushVpSize, viewSize: geometry.size)
                            }
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .scaleEffect(editZoomScale)
                            .offset(editOffset)
                            .gesture(editPanGesture(in: geometry.size, imageSize: geometry.size))
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

                                coordinator: metalCoordinator
                            )
                                .frame(width: geometry.size.width, height: geometry.size.height)

                            // Ellipse mask overlay — only for ellipse masks, and not while the
                            // brush tool is active (its overlay owns the mouse then).
                            if let maskIdx = selectedMaskIndex,
                               let masks = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments,
                               maskIdx < masks.count,
                               masks[maskIdx].brush == nil,
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
                            }

                            // Freeform brush paint overlay (bare "B").
                            brushOverlay(viewportOrigin: vpOrigin, viewportSize: vpSize, viewSize: geometry.size)
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .gesture(editPanGesture(in: geometry.size, imageSize: imageSize))
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
            }
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
                case .ended:
                    isCursorOverPreview = false
                }
            }
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        let dampened = 1.0 + (value.magnification - 1.0) * 0.4
                        if showCropControls {
                            cropZoomScale = (lastCropZoomScale * dampened).clamped(to: 0.25...3.0)
                        } else {
                            editZoomScale = (lastEditZoomScale * dampened).clamped(to: 1.0...10.0)
                            syncViewportToMetal()
                        }
                    }
                    .onEnded { _ in
                        if showCropControls {
                            lastCropZoomScale = cropZoomScale
                        } else {
                            lastEditZoomScale = editZoomScale
                            if editZoomScale <= 1.0 {
                                editOffset = .zero
                                lastEditOffset = .zero
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
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button {
                        onExit()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Exit Edit View (Esc)")
                    Spacer()
                    if canEditSingleImage {
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
                    // ── Mask Selector ──
                    maskSelectorBar

                    if isBrushPainting || selectedMaskIsBrush {
                        brushToolbar
                    }

                    if selectedMaskIndex != nil {
                        maskAdjustmentSliders
                    } else {
                        globalAdjustmentSliders
                    }

                    // ── Crop ──
                    Text("Crop")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    Divider()

                    if metadataViewModel.hasEmbeddedCropNotLoaded {
                        Button {
                            metadataViewModel.importEmbeddedCrop()
                            showCropControls = true
                            commitEditAdjustments()
                        } label: {
                            Label("Load Embedded Crop", systemImage: "square.and.arrow.down")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.orange)
                        .help("Load crop from embedded image metadata")
                    }

                    HStack {
                        Picker(selection: $cropAspectRatio) {
                            ForEach(CropAspectRatio.allCases) { ratio in
                                Text(ratio.label).tag(ratio)
                            }
                        } label: {
                            Label("Aspect Ratio", systemImage: "crop")
                                .labelStyle(.iconOnly)
                        }
                        .pickerStyle(.menu)
                        .disabled(!showCropControls)
                        .onChange(of: cropAspectRatio) { _, newRatio in
                            applyAspectRatioToCrop(newRatio)
                        }

                        Spacer()

                        Button {
                            resetCrop()
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(!isCropEnabled)
                        .help("Reset Crop")
                    }

                    if showCropControls {

                        sliderRow(
                            "Rotation",
                            value: cropAngleBinding,
                            range: -45...45,
                            step: 0.01,
                            formatter: { signedDoubleString($0, precision: 2) },
                            settingsMutator: { [self] settings, value in
                                // Write to @State for immediate visual feedback
                                // (bypasses @Observable cascade — Metal doesn't handle crop)
                                let clampedAngle = min(max(value, -45), 45)
                                let ar = sourceAspectRatio
                                let orientation = selectedImageOrientation
                                let sensorCrop = settings.crop ?? CameraRawCrop(top: 0, left: 0, bottom: 1, right: 1, angle: 0, hasCrop: true)
                                let dCrop = sensorCrop.transformedForDisplay(orientation: orientation)
                                let region = NormalizedCropRegion(
                                    top: dCrop.top ?? 0,
                                    left: dCrop.left ?? 0,
                                    bottom: dCrop.bottom ?? 1,
                                    right: dCrop.right ?? 1
                                )
                                .centerClampedForRotation(angleDegrees: clampedAngle, aspectRatio: ar)
                                .fittingRotated(angleDegrees: clampedAngle, aspectRatio: ar)
                                dragCropAngle = clampedAngle
                                dragCropRegion = region
                            },
                            onReset: {
                                dragCropAngle = nil
                                dragCropRegion = nil
                                cropAngleBinding.wrappedValue = 0
                            }
                        )
                    }

                    if showCropControls {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("Zoom")
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
                                    .help("Reset to 100%")
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
                    }

                    Divider()

                    Button(saveButtonLabel) {
                        saveCurrentRenderedImage()
                    }
                    .disabled(!canEditSingleImage || selectedImageURL == nil || isSavingRenderedJPEG)
                } else {
                    Text("Select exactly one image to edit.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .disabled(isDecodingFullResolution)
            .opacity(isDecodingFullResolution ? 0.6 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isDecodingFullResolution)
        }
    }

    private var filmstrip: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            LazyHStack(spacing: 8) {
                ForEach(browserViewModel.visibleImages) { image in
                    EditFilmstripItemView(
                        image: image,
                        thumbnailService: browserViewModel.thumbnailService,
                        isSelected: browserViewModel.selectedImageIDs.contains(image.url)
                    )
                    .onTapGesture {
                        let modifiers = NSEvent.modifierFlags
                        if modifiers.contains(.command) {
                            // ⌘-click: toggle selection
                            if browserViewModel.selectedImageIDs.contains(image.url) {
                                browserViewModel.selectedImageIDs.remove(image.url)
                            } else {
                                browserViewModel.selectedImageIDs.insert(image.url)
                            }
                        } else if modifiers.contains(.shift), let anchor = browserViewModel.lastClickedImageURL {
                            // Shift-click: range select (O(1) lookup via urlToVisibleIndex)
                            if let anchorIdx = browserViewModel.urlToVisibleIndex[anchor],
                               let clickIdx = browserViewModel.urlToVisibleIndex[image.url] {
                                let images = browserViewModel.visibleImages
                                let range = min(anchorIdx, clickIdx)...max(anchorIdx, clickIdx)
                                for i in range {
                                    browserViewModel.selectedImageIDs.insert(images[i].url)
                                }
                            }
                        } else {
                            // Normal click: single select
                            browserViewModel.selectedImageIDs = [image.url]
                        }
                        browserViewModel.lastClickedImageURL = image.url
                        isWorkspaceFocused = true
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(height: 120)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func handleEditWorkspaceDisappear() {
        // Flush any unsaved edit adjustments (CRS) to disk before tearing down.
        commitEditAdjustments()

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
        previewTask?.cancel()
        previewTask = nil
        previewRenderTask?.cancel()
        previewRenderTask = nil
        scopeThrottleTask?.cancel()
        scopeThrottleTask = nil
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }

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
            metalPipeline = MetalEditPipeline(device: device, commandQueue: queue)
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
        editLog.info("[\(selectedImageURL?.lastPathComponent ?? "nil")] loadSelectedImagePreview triggered by: onAppear")
        loadSelectedImagePreview()
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [self] event in
            handleKeyEvent(event)
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
        previewTask?.cancel()
        previewTask = nil
        previewRenderTask?.cancel()
        previewRenderTask = nil
        sourceImage = nil
        sourceCIImage = nil
        asShotWhiteBalance = nil
        isPickingWhiteBalance = false
        wbPickDragRect = nil
        metalPipeline?.asShotTemperature = 6500
        metalPipeline?.asShotTint = 0
        previewCIImage = nil
        previewImage = nil
        isLoadingPreview = false
        isDecodingFullResolution = false
        isEditFullResLoaded = false
        editFullResTask?.cancel()
        editFullResTask = nil
        metalPipeline?.clearSourceTexture()
        metalPipeline?.updateOverlayParams(geometry: nil, visible: false)
        resetCropZoom()
        resetEditZoom()
        selectedLayer = .global
        if !isCropEnabled {
            showCropControls = false
        }

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

        editLog.info("[\(filename)] loadSelectedImagePreview: starting previewTask (isRaw=\(isRaw), maxPx=\(Int(previewMaxPixelSize)))")

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
                    guard let result = FullScreenImageCache.extractEmbeddedPreviewWithOrientation(
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
                    if let result = FullScreenImageCache.loadHDRPreviewWithOrientation(from: selectedImageURL, maxPixelSize: previewMaxPixelSize) {
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
                    if let result = FullScreenImageCache.loadDownsampledWithOrientation(
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
                        if let result = FullScreenImageCache.loadHDRFullResolutionWithOrientation(from: selectedImageURL) {
                            decoded = result
                        } else if let result = FullScreenImageCache.loadFullResolutionWithOrientation(from: selectedImageURL) {
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
        pipeline: MetalEditPipeline
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

        Task.detached(priority: .background) {
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
        editLog.info("[\(filename)] zoom upgrade: decoding full-res (native \(Int(nativeMax))px, tex \(Int(texMax))px)")

        editFullResTask = Task {
            let start = ContinuousClock.now
            let fullRes: CIImage? = await Task.detached(priority: .userInitiated) {
                let fileOrientation = FullScreenImageCache.fileEXIFOrientation(at: url)
                let decoded: CIImage?
                if isRaw {
                    // nil maxPixelSize → full sensor resolution.
                    decoded = FullScreenImageCache.loadRAWImage(from: url, draftMode: false)?.image
                } else {
                    decoded = FullScreenImageCache.loadHDRFullResolution(from: url)
                        ?? FullScreenImageCache.loadFullResolution(from: url).map { CIImage(cgImage: $0) }
                }
                guard let decoded else { return nil }
                return Self.orientedToTarget(
                    ciImage: decoded, nsImage: nil,
                    from: fileOrientation, to: targetOrientation
                ).ciImage ?? decoded
            }.value

            guard !Task.isCancelled, selectedImageURL == url, let fullRes else {
                editFullResTask = nil
                return
            }
            await Task.detached(priority: .medium) {
                pipeline.uploadSourceImage(fullRes, exifOrientation: targetOrientation)
            }.value
            guard !Task.isCancelled, selectedImageURL == url else {
                editFullResTask = nil
                return
            }
            isEditFullResLoaded = true
            editFullResTask = nil
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

    /// Returns a copy of the given settings with any per-section muted adjustments stripped,
    /// so the pipeline preview reflects the toggled eye-icon state without altering the ViewModel.
    /// `isMutingDevelop` (D key) acts as a universal mute for all adjustment sections.
    private func settingsForPipeline(_ settings: CameraRawSettings?) -> CameraRawSettings? {
        // RAW sources always decode with full EDR headroom; mark the settings so the
        // tone pipeline applies the SDR output tonemap when HDR edit mode is off.
        // With no settings at all (unedited image, "before" view) a RAW source still
        // needs the tonemap-only render to match the SDR baseline appearance.
        let isRawSource = selectedImageURL.map { SupportedImageFormats.isRaw(url: $0) } ?? false
        guard var s = settings else {
            guard isRawSource else { return nil }
            var tonemapOnly = CameraRawSettings()
            tonemapOnly.sourceHasHDRHeadroom = true
            return tonemapOnly
        }
        s.sourceHasHDRHeadroom = isRawSource ? true : nil
        if isMutingDevelop || isMutingColor {
            s.whiteBalance = nil
            s.temperature = nil
            s.tint = nil
            s.incrementalTemperature = nil
            s.incrementalTint = nil
            s.asShotNeutralTemperature = nil
            s.asShotNeutralTint = nil
            s.saturation = nil
            s.vibrance = nil
        }
        if isMutingDevelop || isMutingExposure {
            s.exposure2012 = nil
            s.contrast2012 = nil
            s.highlights2012 = nil
            s.shadows2012 = nil
            s.whites2012 = nil
            s.blacks2012 = nil
        }
        if isMutingDevelop || isMutingToneCurve {
            s.toneCurve = nil
        }
        if isMutingDevelop || isMutingHSL {
            s.hslAdjustments = nil
        }
        if isMutingDevelop {
            s.localAdjustments = nil
        }
        return s
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
            previewImage = sourceImage
            NotificationCenter.default.post(name: .scopeSourceImageDidChange, object: nil, userInfo: ["isHDR": isHDREnabled])
            return
        }

        let settings: CameraRawSettings? = {
            // "Before" still needs the SDR output tonemap for RAW sources so the
            // unedited baseline matches the previous SDR decode appearance.
            if isShowingBefore { return settingsForPipeline(nil) }
            if isMutingGlobal {
                var masksOnly = CameraRawSettings()
                masksOnly.localAdjustments = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments
                masksOnly.hdrEditMode = metadataViewModel.editingMetadata.cameraRaw?.hdrEditMode
                if let url = selectedImageURL, SupportedImageFormats.isRaw(url: url) {
                    masksOnly.sourceHasHDRHeadroom = true
                }
                return masksOnly
            }
            var s = metadataViewModel.editingMetadata.cameraRaw
            if let asShot = asShotWhiteBalance {
                s?.asShotNeutralTemperature = Double(asShot.temperature)
                s?.asShotNeutralTint = Double(asShot.tint)
            }
            return settingsForPipeline(s)
        }()

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
        }
        if lockedCropImageRect != nil {
            editLog.debug("renderPreview: crop interaction path (full-res Metal, skip CGImage)")
            return
        }

        editLog.debug("renderPreview: full path (CGImage generation)")

        // On release / initial load: produce CGImage for scope display and export
        previewRenderTask?.cancel()
        let fullSource = sourceCIImage
        let fallback = sourceImage
        let orientation = selectedImageOrientation

        let hdr = isHDREnabled
        previewRenderTask = Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (NSImage, CGImage, CGImage?)? in
                let output = CameraRawApproximation.apply(to: fullSource, settings: settings, exifOrientation: orientation)
                let ctx = CameraRawApproximation.ciContext
                guard let cgImage = ctx.createCGImage(
                    output,
                    from: output.extent,
                    format: .RGBAh,
                    colorSpace: CameraRawApproximation.workingColorSpace
                ) else {
                    return nil
                }
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))

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

                return (nsImage, cgImage, scopeCGImage)
            }.value

            guard !Task.isCancelled else { return }
            if let result {
                previewImage = result.0
                NotificationCenter.default.post(name: .scopeSourceImageDidChange, object: nil, userInfo: ["cgImage": result.2 ?? result.1, "isHDR": hdr])
            } else {
                previewImage = fallback
                NotificationCenter.default.post(name: .scopeSourceImageDidChange, object: nil, userInfo: ["isHDR": hdr])
            }
        }
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

    /// Scales and positions the image so the crop region fills the view (with padding for handles).
    /// The image may extend beyond the view bounds. The crop rectangle will be centered in the view.
    private func cropFittedImageRect(in containerSize: CGSize, imageSize: CGSize, crop: NormalizedCropRegion, angleDegrees: Double, zoom: CGFloat = 1.0) -> CGRect {
        guard containerSize.width > 0, containerSize.height > 0, imageSize.width > 0, imageSize.height > 0 else {
            return .zero
        }

        let handlePadding: Double = 48
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
        let newSettings = (cameraRawHasEdits(cameraRaw) || cameraRaw.crop?.hasCrop == true) ? cameraRaw : nil
        metadataViewModel.editingMetadata.cameraRaw = newSettings
        metadataViewModel.markChanged()

        editUndoManager.registerUndo(withTarget: metadataViewModel) { vm in
            vm.editingMetadata.cameraRaw = oldSettings
            vm.markChanged()
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
            || cameraRaw.toneCurve != nil
            || (cameraRaw.crop?.isEffectiveCrop == true)
            || !(cameraRaw.localAdjustments?.isEmpty ?? true)
            || !(cameraRaw.hslAdjustments?.isEmpty ?? true)
            || (cameraRaw.anonymizer?.isEmpty == false)
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

    private func toggleCropControls() {
        showCropControls.toggle()
        if showCropControls {
            // Deselect mask and reset edit zoom when entering crop mode
            selectedLayer = .global
            metalPipeline?.updateOverlayParams(geometry: nil, visible: false)
            resetEditZoom()
        }
        if showCropControls && !isCropEnabled {
            // Showing controls — enable crop if not already active
            resetCropZoom()
            updateCameraRaw { cameraRaw in
                var crop = cameraRaw.crop ?? CameraRawCrop()
                crop.hasCrop = true
                if crop.top == nil { crop.top = 0 }
                if crop.left == nil { crop.left = 0 }
                if crop.bottom == nil { crop.bottom = 1 }
                if crop.right == nil { crop.right = 1 }
                if crop.angle == nil { crop.angle = 0 }
                cameraRaw.crop = crop
            }
            if cropAspectRatio != .free {
                applyAspectRatioToCrop(cropAspectRatio)
            }
            commitEditAdjustments()
        }
        if !showCropControls {
            // Reset zoom and unlock image rect when hiding controls
            resetCropZoom()
            lockedCropImageRect = nil
            // Crop tool deactivated — push the now-confirmed crop to the clean feed.
            syncCleanFeed()
        }
    }

    private func resetCrop() {
        resetCropZoom()
        cropAspectRatio = .original
        showCropControls = false
        updateCameraRaw { cameraRaw in
            cameraRaw.crop = CameraRawCrop(
                top: 0,
                left: 0,
                bottom: 1,
                right: 1,
                angle: 0,
                hasCrop: false
            )
        }
        commitEditAdjustments()
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
        let angle = metadataViewModel.editingMetadata.cameraRaw?.crop?.angle ?? 0
        let normalized = crop.fittingRotated(angleDegrees: angle, aspectRatio: sourceAspectRatio)
        let displayCrop = CameraRawCrop(
            top: normalized.top, left: normalized.left,
            bottom: normalized.bottom, right: normalized.right,
            angle: angle, hasCrop: true
        )
        let sensorCrop = displayCrop.transformedForSensor(orientation: selectedImageOrientation)
        updateCameraRaw { cameraRaw in
            cameraRaw.crop = sensorCrop
        }
        if commit {
            commitEditAdjustments()
        }
    }

    private func updateCropAngle(_ angle: Double, commit: Bool) {
        let clampedAngle = min(max(angle, -45), 45)
        let ar = sourceAspectRatio
        let orientation = selectedImageOrientation
        updateCameraRaw { cameraRaw in
            // Read the current sensor crop and transform to display space for angle calculations
            let sensorCrop = cameraRaw.crop ?? CameraRawCrop(top: 0, left: 0, bottom: 1, right: 1, angle: 0, hasCrop: true)
            let displayCrop = sensorCrop.transformedForDisplay(orientation: orientation)
            let region = NormalizedCropRegion(
                top: displayCrop.top ?? 0,
                left: displayCrop.left ?? 0,
                bottom: displayCrop.bottom ?? 1,
                right: displayCrop.right ?? 1
            )
            .centerClampedForRotation(angleDegrees: clampedAngle, aspectRatio: ar)
            .fittingRotated(angleDegrees: clampedAngle, aspectRatio: ar)

            let updatedDisplay = CameraRawCrop(
                top: region.top, left: region.left,
                bottom: region.bottom, right: region.right,
                angle: (clampedAngle * 1000000).rounded() / 1000000,
                hasCrop: true
            )
            cameraRaw.crop = updatedDisplay.transformedForSensor(orientation: orientation)
        }
        if commit {
            commitEditAdjustments()
        }
    }

    /// - Parameter settingsMutator: Applies the raw drag value to a CameraRawSettings copy
    ///   for direct Metal rendering without triggering SwiftUI observation.
    ///   When nil, the slider falls back to updating the binding directly during drag.
    private func sliderRow(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        gradientColors: [Color]? = nil,
        formatter: @escaping (Double) -> String,
        settingsMutator: ((inout CameraRawSettings, Double) -> Void)? = nil,
        onReset: (() -> Void)? = nil
    ) -> some View {
        EditSliderRow(
            label: label,
            value: value,
            range: range,
            step: step,
            gradientColors: gradientColors,
            formatter: formatter,
            onEditingChanged: { editing in
                isDraggingEditSlider = editing
                if !editing {
                    commitEditAdjustments()
                }
            },
            onDragValueChanged: settingsMutator.map { mutator in
                { dragValue in
                    if let pipeline = metalPipeline, pipeline.hasSourceTexture {
                        var settings = metadataViewModel.editingMetadata.cameraRaw ?? CameraRawSettings()
                        mutator(&settings, dragValue)
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
            }
        )
    }

    // MARK: - Global Adjustment Sliders

    @ViewBuilder
    private var globalAdjustmentSliders: some View {
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

        sliderRow("Saturation", value: toneSliderBinding(\.saturation), range: -100...100, step: 1, gradientColors: [.gray, .red], formatter: signedIntString, settingsMutator: { $0.saturation = Int($1.rounded()) }, onReset: {
            toneSliderBinding(\.saturation).wrappedValue = 0
        })
        sliderRow("Vibrance", value: toneSliderBinding(\.vibrance), range: -100...100, step: 1, gradientColors: [.gray, .orange], formatter: signedIntString, settingsMutator: { $0.vibrance = Int($1.rounded()) }, onReset: {
            toneSliderBinding(\.vibrance).wrappedValue = 0
        })

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

        sliderRow("Contrast", value: toneSliderBinding(\.contrast2012), range: -100...100, step: 1, formatter: signedIntString, settingsMutator: { $0.contrast2012 = Int($1.rounded()) }, onReset: {
            toneSliderBinding(\.contrast2012).wrappedValue = 0
        })
        sliderRow("Highlights", value: toneSliderBinding(\.highlights2012), range: -100...100, step: 1, formatter: signedIntString, settingsMutator: { $0.highlights2012 = Int($1.rounded()) }, onReset: {
            toneSliderBinding(\.highlights2012).wrappedValue = 0
        })
        sliderRow("Shadows", value: toneSliderBinding(\.shadows2012), range: -100...100, step: 1, formatter: signedIntString, settingsMutator: { $0.shadows2012 = Int($1.rounded()) }, onReset: {
            toneSliderBinding(\.shadows2012).wrappedValue = 0
        })
        sliderRow("Whites", value: toneSliderBinding(\.whites2012), range: -100...100, step: 1, formatter: signedIntString, settingsMutator: { $0.whites2012 = Int($1.rounded()) }, onReset: {
            toneSliderBinding(\.whites2012).wrappedValue = 0
        })
        sliderRow("Blacks", value: toneSliderBinding(\.blacks2012), range: -100...100, step: 1, formatter: signedIntString, settingsMutator: { $0.blacks2012 = Int($1.rounded()) }, onReset: {
            toneSliderBinding(\.blacks2012).wrappedValue = 0
        })

        // ── Tone Curve ──
        CurveEditorView(
            toneCurve: toneCurveBinding,
            isMuted: $isMutingToneCurve,
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

        // ── Hue / Saturation / Density ──
        sectionHeader("Hue / Saturation / Density", isMuted: $isMutingHSL, hasAdjustments: hasHSLAdjustments, onReset: resetHSLAdjustments)
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

        // ── Anonymizer ──
        HStack(spacing: 6) {
            Text("Anonymizer")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .onTapGesture(count: 2) {
                    if hasAnonymizerAdjustments { resetAnonymizerAdjustments() }
                }
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
        .disabled(anonymizerBlackOutBinding.wrappedValue)

        Toggle("Black out", isOn: anonymizerBlackOutBinding)
            .toggleStyle(.checkbox)
            .help("Fully redact this region instead of the mosaic effect")
    }

    // MARK: - Section Headers

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
                isMutingColor.toggle()
                renderPreview()
            } label: {
                Image(systemName: isMutingColor ? "eye.slash" : "eye")
                    .font(.system(size: 11))
                    .foregroundStyle(isMutingColor ? .orange : .secondary)
            }
            .buttonStyle(.plain)
            .help(isMutingColor ? "Show color" : "Hide color")
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
                isMutingExposure.toggle()
                renderPreview()
            } label: {
                Image(systemName: isMutingExposure ? "eye.slash" : "eye")
                    .font(.system(size: 11))
                    .foregroundStyle(isMutingExposure ? .orange : .secondary)
            }
            .buttonStyle(.plain)
            .help(isMutingExposure ? "Show exposure adjustments" : "Hide exposure adjustments")
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
                HStack(spacing: 6) {
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
            }
        }
    }

    /// Whether the currently-selected layer is a freeform brush mask.
    private var selectedMaskIsBrush: Bool {
        guard let id = selectedMaskID else { return false }
        return metadataViewModel.editingMetadata.cameraRaw?.localAdjustments?
            .first(where: { $0.id == id })?.brush != nil
    }

    /// Brush-settings toolbar, shown while the brush tool is active or a brush mask is selected.
    /// The "Paint" toggle mirrors the bare-`B` shortcut so the tool is discoverable without it;
    /// the sliders describe what's about to be painted (already-painted strokes keep their own).
    private var brushToolbar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "paintbrush.pointed")
                Text("Brush").font(.system(size: 11, weight: .semibold))
                Spacer()
                Toggle(isOn: $isBrushPainting) {
                    Text(isBrushPainting ? "Painting" : "Paint")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Toggle the paint tool (shortcut: B)")
            }
            Picker("", selection: $brushErase) {
                Text("Add").tag(false)
                Text("Erase").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            brushSlider("Size", value: $brushRadius, range: 0.005...0.20)
            brushSlider("Hardness", value: $brushHardness, range: 0...1)
            brushSlider("Flow", value: $brushFlow, range: 0.05...1)
            Text(isBrushPainting ? "Drag on the image to paint. Press B to exit."
                                 : "Turn on Paint (or press B), then drag on the image.")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
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

    private var addLayerButton: some View {
        Button {
            addNewMask()
        } label: {
            VStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3]))
                    .foregroundStyle(.secondary)
                    .frame(width: 56, height: 56)
                    .overlay(
                        Image(systemName: "plus")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    )
                Text("Add")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .frame(width: 60)
            }
        }
        .buttonStyle(.plain)
        .help("Add mask adjustment")
    }

    @ViewBuilder
    private func layerCard(_ ref: LayerRef) -> some View {
        let mask = maskFor(ref)
        let isSelected = ref == selectedLayer
        let muted = mask.map { !$0.enabled } ?? false
        let kind: LayerKind = mask?.layerKind ?? .global

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
                .brightness(-0.05)
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
        }
        .contentShape(Rectangle())
        .opacity(draggingLayer == ref ? 0.4 : 1)
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
                Button(mask.enabled ? "Mute" : "Enable") { toggleMaskEnabled(mask.id) }
                Button(mask.inverted ? "Normal (inside ellipse)" : "Invert (outside ellipse)") {
                    toggleMaskInverted(mask.id)
                }
                Divider()
                Button("Delete", role: .destructive) {
                    selectedLayer = ref
                    deleteSelectedMask()
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
                Button {
                    toggleMaskInverted(id)
                } label: {
                    Image(systemName: mask.inverted ? "circle.dashed.inset.filled" : "circle.dashed")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(mask.inverted ? "Invert: adjustments apply outside ellipse" : "Normal: adjustments apply inside ellipse")

                Button {
                    toggleMaskEnabled(id)
                } label: {
                    Image(systemName: mask.enabled ? "eye" : "eye.slash")
                        .font(.system(size: 11))
                        .foregroundStyle(mask.enabled ? Color.secondary : Color.red)
                }
                .buttonStyle(.plain)
                .help(mask.enabled ? "Mute mask effect" : "Enable mask effect")

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

    private func layerName(_ ref: LayerRef, mask: MaskAdjustment?) -> String {
        switch ref {
        case .global: return "Global"
        case .mask:   return mask?.name ?? "Mask"
        }
    }

    private func layerRefString(_ ref: LayerRef) -> String {
        switch ref {
        case .global:        return "global"
        case .mask(let id):  return "mask:\(id.uuidString)"
        }
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
    private var maskAdjustmentSliders: some View {
        if let idx = selectedMaskIndex,
           let masks = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments,
           idx < masks.count {

            Text("Mask Adjustments")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Divider()

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
                settingsMutator: { settings, value in
                    settings.localAdjustments?[idx].vibrance = Int(value.rounded()) == 0 ? nil : Int(value.rounded())
                },
                onReset: {
                    maskIntBinding(idx, \.vibrance).wrappedValue = 0
                }
            )
            // ── Anonymizer ──
            Text("Anonymizer")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            Divider()

            sliderRow(
                "Anonymizer",
                value: maskAnonymizerAmountBinding(idx),
                range: 0...100,
                step: 1,
                formatter: { "\(Int($0.rounded()))" },
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
            .disabled(maskAnonymizerBlackOutBinding(idx).wrappedValue)

            Toggle("Black out", isOn: maskAnonymizerBlackOutBinding(idx))
                .toggleStyle(.checkbox)
                .help("Fully redact this mask instead of the mosaic effect")

            // ── Mask Shape ──
            Text("Mask Shape")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            Divider()

            sliderRow(
                "Feather",
                value: maskGeometryBinding(idx, \.feather),
                range: 0...100,
                step: 1,
                formatter: { "\(Int($0.rounded()))" },
                settingsMutator: { settings, value in
                    settings.localAdjustments?[idx].geometry.feather = value.rounded()
                },
                onReset: {
                    maskGeometryBinding(idx, \.feather).wrappedValue = 50
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

    /// Live array index of the selected mask in `localAdjustments`, or nil when Global is
    /// selected (or the selected mask was deleted). Resolved by UUID every access so it stays
    /// correct after reordering — callers index `localAdjustments` with the current value.
    private var selectedMaskIndex: Int? {
        guard case .mask(let id) = selectedLayer else { return nil }
        return metadataViewModel.editingMetadata.cameraRaw?.localAdjustments?.firstIndex { $0.id == id }
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
                updateCameraRaw { cameraRaw in
                    guard let masks = cameraRaw.localAdjustments, maskIndex < masks.count else { return }
                    let clamped = min(max(newValue.rounded(), 0), 100)
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

    private func addNewMask() {
        let existingCount = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments?.count ?? 0
        var geo = EllipseMaskGeometry()
        // Make the mask a circle by compensating for image aspect ratio
        if let size = currentImageSize, size.height > 0 {
            geo.radiusY = geo.radiusX * size.width / size.height
        }
        // The default geometry is authored in the display frame; storage is sensor-frame.
        geo = maskGeometryForSensor(geo)
        let newMask = MaskAdjustment(name: "Mask \(existingCount + 1)", geometry: geo)
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
            if mask.brush != nil { slice += 1 }
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
        // Rebuild params so a freshly-created mask's alpha slice is allocated before live stamping.
        if let pipeline = metalPipeline, pipeline.hasSourceTexture {
            pipeline.updateParams(settingsForPipeline(metadataViewModel.editingMetadata.cameraRaw))
        }
        return brushSliceIndex(forMaskID: targetID)
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
                onStrokeEnded: { stroke in commitBrushStroke(stroke) }
            )
            .frame(width: viewSize.width, height: viewSize.height)
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

    private var hasHSLAdjustments: Bool {
        !(metadataViewModel.editingMetadata.cameraRaw?.hslAdjustments?.isEmpty ?? true)
    }

    private var hasAnonymizerAdjustments: Bool {
        !(metadataViewModel.editingMetadata.cameraRaw?.anonymizer?.isEmpty ?? true)
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
            cameraRaw.localAdjustments = nil
            cameraRaw.anonymizer = nil
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
            cameraRaw.toneCurve = nil
            cameraRaw.localAdjustments = nil
            cameraRaw.anonymizer = nil
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
            do {
                let outputFolder = selectedImageURL.deletingLastPathComponent().appendingPathComponent("Edited", isDirectory: true)
                try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
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
            } catch {
                saveError = "Failed to save image: \(error.localizedDescription)"
            }
            isSavingRenderedJPEG = false
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
            cameraRaw.toneCurve = source.toneCurve
            cameraRaw.hslAdjustments = source.hslAdjustments
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
        cropZoomScale = 1.0
        lastCropZoomScale = 1.0
    }

    // MARK: - Edit Zoom / Pan

    private let maxEditZoom: CGFloat = 10.0

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

    /// Sync the current zoom/pan state to the Metal pipeline's viewport parameters.
    /// When crop is active, the MetalPreviewView frame already matches the source aspect
    /// ratio (via cropFittedImageRect), so the shader uses an identity viewport.
    private func syncViewportToMetal() {
        if (isCropEnabled || showCropControls), !isShowingBefore {
            // Crop path: frame matches source aspect → identity viewport (stretch-to-fill)
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
        editZoomScale = 1.0
        lastEditZoomScale = 1.0
        editOffset = .zero
        lastEditOffset = .zero
        syncViewportToMetal()
    }

    private func handleEditScrollZoom(delta: CGFloat, event: NSEvent) {
        let zoomFactor = 1.0 + (delta * 0.01)
        let oldScale = editZoomScale
        let newScale = (oldScale * zoomFactor).clamped(to: 1.0...maxEditZoom)
        guard newScale != oldScale else { return }

        if newScale <= 1.0 {
            editZoomScale = newScale
            lastEditZoomScale = newScale
            editOffset = .zero
            lastEditOffset = .zero
            syncViewportToMetal()
            return
        }

        // Cursor-anchored zoom in viewport UV space: compute which UV coordinate
        // is under the cursor, then solve for the offset that keeps it there
        // after the zoom change.
        let containerSize = previewPaneFrame.size
        guard containerSize.width > 0, containerSize.height > 0,
              let imageSize = metalImageSize else {
            editZoomScale = newScale
            lastEditZoomScale = newScale
            syncViewportToMetal()
            return
        }

        let cursorFromCenter = editCursorFromCenter(event: event)
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

        editZoomScale = newScale
        lastEditZoomScale = newScale
        editOffset = newOffset
        lastEditOffset = newOffset

        // Constrain to valid bounds
        let scaledWidth = fittedWidth * newScale
        let scaledHeight = fittedHeight * newScale
        let maxOffsetX = max(0, (scaledWidth - containerSize.width) / 2)
        let maxOffsetY = max(0, (scaledHeight - containerSize.height) / 2)
        editOffset = CGSize(
            width: editOffset.width.clamped(to: -maxOffsetX...maxOffsetX),
            height: editOffset.height.clamped(to: -maxOffsetY...maxOffsetY)
        )
        lastEditOffset = editOffset

        syncViewportToMetal()
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

    private func editPanGesture(in containerSize: CGSize, imageSize: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard editZoomScale > 1.0 else { return }
                editOffset = CGSize(
                    width: lastEditOffset.width + value.translation.width,
                    height: lastEditOffset.height + value.translation.height
                )
                syncViewportToMetal()
            }
            .onEnded { _ in
                guard editZoomScale > 1.0 else {
                    editOffset = .zero
                    lastEditOffset = .zero
                    syncViewportToMetal()
                    return
                }
                lastEditOffset = editOffset
                constrainEditOffset(in: containerSize, imageSize: imageSize)
            }
    }

    private func constrainEditOffset(in containerSize: CGSize, imageSize: CGSize) {
        let imgSize = metalImageSize ?? imageSize
        let fittedScale = min(containerSize.width / imgSize.width,
                              containerSize.height / imgSize.height)
        let scaledWidth = imgSize.width * fittedScale * editZoomScale
        let scaledHeight = imgSize.height * fittedScale * editZoomScale
        let maxOffsetX = max(0, (scaledWidth - containerSize.width) / 2)
        let maxOffsetY = max(0, (scaledHeight - containerSize.height) / 2)
        editOffset = CGSize(
            width: editOffset.width.clamped(to: -maxOffsetX...maxOffsetX),
            height: editOffset.height.clamped(to: -maxOffsetY...maxOffsetY)
        )
        lastEditOffset = editOffset
        syncViewportToMetal()
    }

    private func toggleEditZoom() {
        let containerSize = previewPaneFrame.size
        guard containerSize.width > 0, containerSize.height > 0 else { return }

        let zoom100 = calculateEditZoomTo100(in: containerSize)
        let isAt100 = abs(editZoomScale - zoom100) < 0.01

        if isAt100 || editZoomScale > 1.0 {
            // Return to fit
            editZoomScale = 1.0
            editOffset = .zero
        } else {
            // Zoom to 100% (clamped to max)
            editZoomScale = min(zoom100, maxEditZoom)
        }
        lastEditZoomScale = editZoomScale
        lastEditOffset = editOffset
        syncViewportToMetal()
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
            onExit()
            return nil
        }

        // M key — hold to show before, release to hide
        if chars == "m" {
            if isKeyUp {
                isShowingBefore = false
                return nil
            }
            guard !isTextFieldActive(), canEditSingleImage else { return event }
            isShowingBefore = true
            return nil
        }

        // Cmd+D — hold to mute only the current layer (global or selected mask)
        if chars == "d" && modifiers.contains(.command) {
            if isKeyUp {
                if isMutingSelectedMask {
                    if let idx = mutedMaskIndex {
                        metadataViewModel.editingMetadata.cameraRaw?.localAdjustments?[idx].enabled = true
                        mutedMaskIndex = nil
                    }
                    isMutingSelectedMask = false
                } else if isMutingGlobal {
                    isMutingGlobal = false
                    renderPreview()
                }
                return nil
            }
            guard !isTextFieldActive(), canEditSingleImage else { return nil }
            if let idx = selectedMaskIndex {
                // Mute selected mask
                guard let masks = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments,
                      idx < masks.count, masks[idx].enabled else { return nil }
                isMutingSelectedMask = true
                mutedMaskIndex = idx
                metadataViewModel.editingMetadata.cameraRaw?.localAdjustments?[idx].enabled = false
            } else {
                // Mute global adjustments — send masks-only settings to pipeline
                isMutingGlobal = true
                var masksOnly = CameraRawSettings()
                masksOnly.localAdjustments = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments
                masksOnly.hdrEditMode = metadataViewModel.editingMetadata.cameraRaw?.hdrEditMode
                if let url = selectedImageURL, SupportedImageFormats.isRaw(url: url) {
                    masksOnly.sourceHasHDRHeadroom = true
                }
                metalPipeline?.updateParams(masksOnly)
                metalCoordinator.requestRedraw()
                renderPreview()
            }
            return nil
        }

        // D key — hold to disable develop adjustments (keep crop visible)
        if chars == "d" && modifiers.isDisjoint(with: [.command, .option, .control]) {
            if isKeyUp {
                isMutingDevelop = false
                return nil
            }
            guard !isTextFieldActive(), canEditSingleImage else { return event }
            isMutingDevelop = true
            return nil
        }

        // All remaining handlers are key-down only
        guard isKeyDown else { return event }
        guard !isTextFieldActive() else { return event }

        // Arrow keys
        if event.keyCode == 123 { // left arrow
            browserViewModel.selectPrevious()
            return nil
        }
        if event.keyCode == 124 { // right arrow
            browserViewModel.selectNext()
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
            addNewMask()
            return nil
        }

        // B — toggle the freeform brush paint tool (Photoshop convention). Turning it on
        // deselects the WB eyedropper so the two drag-driven tools don't fight over the mouse.
        if chars == "b" && modifiers.isDisjoint(with: [.command, .option, .control]) {
            guard canEditSingleImage else { return event }
            isBrushPainting.toggle()
            if isBrushPainting { isPickingWhiteBalance = false }
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
                if let cursor, let readout {
                    WhiteBalanceReadout(color: readout)
                        .allowsHitTesting(false)
                        .alignmentGuide(.leading) { _ in -(cursor.x + 16) }
                        .alignmentGuide(.top) { _ in -(cursor.y + 16) }
                }
            }
            // Crosshair cursor on top: a cursorUpdate tracking area re-asserts the cursor on
            // every mouse-move, so the Metal view's own tracking area can't reset it to the
            // arrow (a one-shot NSCursor.push does get overridden).
            .overlay { CrosshairCursorView().allowsHitTesting(false) }
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
