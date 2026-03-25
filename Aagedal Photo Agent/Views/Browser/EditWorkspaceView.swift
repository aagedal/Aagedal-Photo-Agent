import AppKit
import CoreImage
import os
import SwiftUI

nonisolated(unsafe) private let editLog = Logger(
    subsystem: "com.aagedal.photo-agent", category: "EditWorkspace"
)

struct EditWorkspaceView: View {
    @Bindable var metadataViewModel: MetadataViewModel
    @Bindable var browserViewModel: BrowserViewModel
    let settingsViewModel: SettingsViewModel
    let scopeViewModel: ScopeViewModel
    let onExit: () -> Void
    var onPendingStatusChanged: (() -> Void)?

    @State private var sourceImage: NSImage?
    @State private var sourceCIImage: CIImage?
    @State private var isDraggingEditSlider = false
    @State private var previewCIImage: CIImage?
    @State private var previewImage: NSImage?
    @State private var previewCGImage: CGImage?
    @State private var previewTask: Task<Void, Never>?
    @State private var previewRenderTask: Task<Void, Never>?
    @State private var isLoadingPreview = false
    @State private var isDecodingFullResolution = false
    @State private var isSavingRenderedJPEG = false
    @State private var copyPasteFeedback: String?
    @State private var cropZoomScale: CGFloat = 1.0
    @State private var lastCropZoomScale: CGFloat = 1.0
    @State private var cropAspectRatio: CropAspectRatio = .original
    @State private var isCursorOverPreview = false
    @State private var scrollEventMonitor: Any?
    @State private var keyEventMonitor: Any?
    @State private var isShowingBefore = false
    @State private var isMutingDevelop = false
    @State private var showCropControls = false
    @State private var lockedCropImageRect: CGRect?
    @State private var dragCropAngle: Double?
    @State private var dragCropRegion: NormalizedCropRegion?
    @State private var editUndoManager = UndoManager()
    @State private var metalPipeline: MetalEditPipeline?
    @State private var metalCoordinator = MetalPreviewView.Coordinator()
    @State private var selectedMaskIndex: Int? = nil
    @State private var isDraggingMask = false
    @State private var dragMaskGeometry: EllipseMaskGeometry?
    @State private var scopeThrottleTask: Task<Void, Never>?
    @State private var lastScopeUpdateTime: ContinuousClock.Instant = .now
    @State private var editZoomScale: CGFloat = 1.0
    @State private var lastEditZoomScale: CGFloat = 1.0
    @State private var editOffset: CGSize = .zero
    @State private var lastEditOffset: CGSize = .zero
    @State private var previewPaneFrame: CGRect = .zero
    @FocusState private var isWorkspaceFocused: Bool

    private static let previewBackground = Color(red: 0.15, green: 0.15, blue: 0.15)

    private static let minKelvin = 2000.0
    private static let maxKelvin = 50000.0

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
                    browserViewModel.thumbnailService.invalidateThumbnail(for: url)
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
        .focusable()
        .focused($isWorkspaceFocused)
        .focusEffectDisabled()
        .onTapGesture {
            isWorkspaceFocused = true
        }
        .onAppear {
            ensureSingleSelection()
            if metalPipeline == nil {
                let device = MetalPreviewView.Coordinator.device
                let queue = MetalPreviewView.Coordinator.commandQueue
                metalPipeline = MetalEditPipeline(device: device, commandQueue: queue)
                // Pre-warm CIContext's CITemperatureAndTint Metal kernels in the background
                // so the first white balance slider drag doesn't stall for ~5s.
                if let pipeline = metalPipeline {
                    Task.detached(priority: .low) {
                        pipeline.warmupCIContext()
                    }
                }
            }
            // Create Metal scope pipeline and share edit pipeline references
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
            metadataViewModel.isInEditView = true
            editLog.info("[\(selectedImageURL?.lastPathComponent ?? "nil")] loadSelectedImagePreview triggered by: onAppear")
            loadSelectedImagePreview()
            keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
                return handleKeyEvent(event)
            }
        }
        .onDisappear {
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
        .onChange(of: isDraggingEditSlider) { wasDragging, isDragging in
            NotificationCenter.default.post(
                name: .editSliderDragStateChanged,
                object: nil,
                userInfo: ["isDragging": isDragging]
            )
            if isDragging, !wasDragging {
                metalCoordinator.startContinuousRendering()
            }
            if wasDragging, !isDragging {
                // Commit crop drag to ViewModel before clearing overlay state
                if let angle = dragCropAngle {
                    updateCropAngle(angle, commit: false)
                }
                dragCropAngle = nil
                dragCropRegion = nil
                metalCoordinator.stopContinuousRendering()
                scopeThrottleTask?.cancel()
                scopeThrottleTask = nil
                renderPreview()
            }
        }
        .onChange(of: selectedImage?.exifOrientation) { oldVal, newVal in
            editLog.info("[\(selectedImageURL?.lastPathComponent ?? "nil")] loadSelectedImagePreview triggered by: onChange(exifOrientation) \(oldVal ?? 0) → \(newVal ?? 0)")
            loadSelectedImagePreview()
        }
        .onChange(of: selectedMaskIndex) { _, _ in
            // Clear Metal overlay — the SwiftUI EllipseMaskOverlayView handles
            // static display with interactive handles. Metal overlay is only used
            // during active mask drags for real-time feedback.
            metalPipeline?.updateOverlayParams(geometry: nil, visible: false)
            metalCoordinator.requestRedraw()
        }
        .onReceive(NotificationCenter.default.publisher(for: .addNewMask)) { _ in
            guard canEditSingleImage else { return }
            addNewMask()
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
                                isHDR: isHDREnabled && !isMutingDevelop,
                                metalPipeline: metalPipeline,
                                useComputeShader: !isShowingBefore && !isMutingDevelop && metalPipeline?.hasSourceTexture == true,

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
                                        let oldAngle = dragCropAngle ?? activeCropAngle
                                        let currentRegion = dragCropRegion ?? activeCrop
                                        let ar = sourceAspectRatio
                                        // Recalculate crop to fit within rotated image bounds
                                        let fitted = currentRegion
                                            .withAngle(from: oldAngle, to: clampedAngle, aspectRatio: ar)
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
                                    isHDR: isHDREnabled && !isMutingDevelop,
                                    metalPipeline: metalPipeline,
                                    useComputeShader: !isShowingBefore && !isMutingDevelop && metalPipeline?.hasSourceTexture == true,

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
                            }
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .scaleEffect(editZoomScale)
                            .offset(editOffset)
                            .gesture(editPanGesture(in: geometry.size, imageSize: geometry.size))
                        }
                    } else {
                        // Normal fit: image fits within view, with zoom/pan support
                        let imageRect = fittedImageRect(in: geometry.size, imageSize: imageSize)

                        ZStack {
                            MetalPreviewView(
                                ciImage: displayCIImage,
                                isHDR: isHDREnabled && !isShowingBefore && !isMutingDevelop,
                                metalPipeline: metalPipeline,
                                useComputeShader: !isShowingBefore && !isMutingDevelop && metalPipeline?.hasSourceTexture == true,

                                coordinator: metalCoordinator
                            )
                                .frame(width: imageRect.width, height: imageRect.height)
                                .position(x: geometry.size.width * 0.5, y: geometry.size.height * 0.5)

                            // Ellipse mask overlay
                            if let maskIdx = selectedMaskIndex,
                               let masks = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments,
                               maskIdx < masks.count,
                               !isShowingBefore {
                                EllipseMaskOverlayView(
                                    imageRect: imageRect,
                                    viewSize: geometry.size,
                                    geometry: dragMaskGeometry ?? masks[maskIdx].geometry,
                                    inverted: masks[maskIdx].inverted,
                                    useMetalOverlay: false,
                                    onStart: {
                                        isDraggingMask = true
                                        isDraggingEditSlider = true
                                    },
                                    onChange: { newGeometry in
                                        // Track drag geometry locally — bypass ViewModel
                                        dragMaskGeometry = newGeometry
                                        // Direct Metal update for real-time preview + scope
                                        if let pipeline = metalPipeline, pipeline.hasSourceTexture {
                                            var settings = metadataViewModel.editingMetadata.cameraRaw ?? CameraRawSettings()
                                            settings.localAdjustments?[maskIdx].geometry = newGeometry
                                            pipeline.updateParams(settings)
                                            pipeline.updateOverlayParams(geometry: newGeometry, visible: true)
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
                                        metalPipeline?.updateOverlayParams(geometry: nil, visible: false)
                                        isDraggingMask = false
                                        isDraggingEditSlider = false
                                        commitEditAdjustments()
                                    }
                                )
                            }
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .scaleEffect(editZoomScale)
                        .offset(editOffset)
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
                        .onAppear { previewPaneFrame = proxy.frame(in: .global) }
                        .onChange(of: proxy.size) { _, _ in previewPaneFrame = proxy.frame(in: .global) }
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
                        }
                    }
                    .onEnded { _ in
                        if showCropControls {
                            lastCropZoomScale = cropZoomScale
                        } else {
                            lastEditZoomScale = editZoomScale
                            if editZoomScale <= 1.0 {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    editOffset = .zero
                                    lastEditOffset = .zero
                                }
                            }
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

                    if selectedMaskIndex != nil {
                        maskAdjustmentSliders
                    } else {

                    // ── Color ──
                    Text("Color")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Divider()

                    if usesIncrementalWhiteBalance {
                        sliderRow(
                            "WB Temp",
                            value: whiteBalanceTemperatureBinding,
                            range: -100...100,
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
                            whiteBalanceTintBinding.wrappedValue = 0
                        }
                    )

                    sliderRow("Saturation", value: toneSliderBinding(\.saturation), range: -100...100, step: 1, gradientColors: [.gray, .red], formatter: signedIntString, settingsMutator: { $0.saturation = Int($1.rounded()) }, onReset: {
                        toneSliderBinding(\.saturation).wrappedValue = 0
                    })
                    sliderRow("Vibrance", value: toneSliderBinding(\.vibrance), range: -100...100, step: 1, gradientColors: [.gray, .orange], formatter: signedIntString, settingsMutator: { $0.vibrance = Int($1.rounded()) }, onReset: {
                        toneSliderBinding(\.vibrance).wrappedValue = 0
                    })

                    // ── Exposure ──
                    Text("Exposure")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
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
                        onDragCurveChanged: { dragCurve in
                            if let pipeline = metalPipeline, pipeline.hasSourceTexture {
                                var settings = metadataViewModel.editingMetadata.cameraRaw ?? CameraRawSettings()
                                settings.toneCurve = dragCurve
                                pipeline.updateParams(settings)
                                metalCoordinator.requestRedraw()
                            }
                        },
                        onEditingChanged: { editing in
                            isDraggingEditSlider = editing
                            if !editing {
                                commitEditAdjustments()
                            }
                        }
                    )
                    .padding(.top, 2)

                    } // end global adjustments else block

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
                                let oldAngle = dCrop.angle ?? 0
                                let region = NormalizedCropRegion(
                                    top: dCrop.top ?? 0,
                                    left: dCrop.left ?? 0,
                                    bottom: dCrop.bottom ?? 1,
                                    right: dCrop.right ?? 1
                                )
                                .withAngle(from: oldAngle, to: clampedAngle, aspectRatio: ar)
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

                    VStack(spacing: 1) {
                        Toggle(isOn: hdrToggleBinding) {
                            Text("HDR")
                                .font(.caption)
                        }
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .disabled(!canEditSingleImage)
                        Text("Experimental")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                    .help("HDR export brightness may vary across viewers")

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
                            // Shift-click: range select
                            let images = browserViewModel.visibleImages
                            if let anchorIdx = images.firstIndex(where: { $0.url == anchor }),
                               let clickIdx = images.firstIndex(where: { $0.url == image.url }) {
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

    private func loadSelectedImagePreview() {
        let filename = selectedImageURL?.lastPathComponent ?? "nil"
        editLog.info("[\(filename)] loadSelectedImagePreview: resetting state, cancelling previous tasks")
        previewTask?.cancel()
        previewTask = nil
        previewRenderTask?.cancel()
        previewRenderTask = nil
        sourceImage = nil
        sourceCIImage = nil
        previewCIImage = nil
        previewImage = nil
        isLoadingPreview = false
        isDecodingFullResolution = false
        metalPipeline?.clearSourceTexture()
        metalPipeline?.updateOverlayParams(geometry: nil, visible: false)
        resetCropZoom()
        resetEditZoom()
        selectedMaskIndex = nil
        if !isCropEnabled {
            showCropControls = false
        }

        guard let selectedImageURL else {
            editLog.info("[nil] loadSelectedImagePreview: no selectedImageURL, returning")
            return
        }
        let previewMaxPixelSize = previewWorkingMaxPixelSize
        isLoadingPreview = true
        let isRaw = SupportedImageFormats.isRaw(url: selectedImageURL)
        editLog.info("[\(filename)] loadSelectedImagePreview: starting previewTask (isRaw=\(isRaw), maxPx=\(Int(previewMaxPixelSize)))")

        previewTask = Task {
            guard !Task.isCancelled else {
                editLog.info("[\(filename)] previewTask: cancelled before start")
                return
            }

            if isRaw {
                // RAW three-phase load: embedded JPEG preview (instant), then
                // CIRAWFilter draft decode at full sensor resolution (fast), then
                // full-quality refinement in background.

                // Phase 1: Extract embedded JPEG preview from RAW container (no RAW decode)
                let phase1Start = ContinuousClock.now
                let quickPreview = await Task.detached(priority: .userInitiated) { () -> (image: NSImage, ciImage: CIImage)? in
                    guard let cgImage = FullScreenImageCache.extractEmbeddedPreview(
                        from: selectedImageURL
                    ) else { return nil }
                    let nsImage = NSImage(
                        cgImage: cgImage,
                        size: NSSize(width: cgImage.width, height: cgImage.height)
                    )
                    return (image: nsImage, ciImage: CIImage(cgImage: cgImage))
                }.value
                let phase1Elapsed = ContinuousClock.now - phase1Start

                guard !Task.isCancelled else {
                    editLog.info("[\(filename)] Phase 1: cancelled after \(phase1Elapsed)")
                    return
                }

                if let quickPreview {
                    editLog.info("[\(filename)] Phase 1: embedded preview in \(phase1Elapsed) (\(quickPreview.image.size.width)x\(quickPreview.image.size.height))")
                    sourceImage = quickPreview.image
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

                renderPreview()
                isLoadingPreview = false
                isDecodingFullResolution = true

                // Phase 2: CIRAWFilter decode at full sensor resolution → Metal texture.
                // After upload, materialize sourceCIImage at screen resolution to release
                // the heavyweight CIRAWFilter pipeline (~260MB per instance).
                if let pipeline = metalPipeline {
                    let cacheHit = pipeline.applyCachedTexture(for: selectedImageURL)
                    editLog.info("[\(filename)] Phase 2: starting (cacheHit=\(cacheHit))")

                    let phase2Start = ContinuousClock.now
                    let rawCIImage: CIImage? = await Task.detached(priority: .userInitiated) {
                        FullScreenImageCache.loadRAWImage(
                            from: selectedImageURL, draftMode: true
                        )
                    }.value
                    let decodeElapsed = ContinuousClock.now - phase2Start

                    guard !Task.isCancelled else {
                        editLog.info("[\(filename)] Phase 2: cancelled after decode (\(decodeElapsed))")
                        return
                    }
                    editLog.info("[\(filename)] Phase 2: decoded in \(decodeElapsed) (result=\(rawCIImage != nil))")

                    if !cacheHit, let rawCIImage {
                        let uploadStart = ContinuousClock.now
                        await Task.detached(priority: .medium) {
                            pipeline.uploadSourceImage(rawCIImage)
                        }.value
                        let uploadElapsed = ContinuousClock.now - uploadStart
                        guard !Task.isCancelled else {
                            editLog.info("[\(filename)] Phase 2: cancelled after upload (\(uploadElapsed))")
                            return
                        }
                        editLog.info("[\(filename)] Phase 2: texture uploaded in \(uploadElapsed)")
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
                    renderPreview()

                    // Pre-cache adjacent RAW images at screen resolution for instant navigation.
                    precacheAdjacentRAWTextures(
                        currentURL: selectedImageURL,
                        pipeline: pipeline
                    )
                }
            } else {
                // Non-RAW: HDR-preserving path (keeps float values >1.0 for HEIC-HLG, AVIF, JXL).
                // Falls back to SDR CGImageSource path for formats CIImage can't decode.
                let previewSource = await Task.detached(priority: .medium) { () -> (image: NSImage?, ciImage: CIImage?) in
                    if let ciImage = FullScreenImageCache.loadHDRPreview(from: selectedImageURL, maxPixelSize: previewMaxPixelSize) {
                        let ctx = CameraRawApproximation.ciContext
                        if let cgImage = ctx.createCGImage(ciImage, from: ciImage.extent, format: .RGBAh, colorSpace: CameraRawApproximation.workingColorSpace) {
                            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                            return (image: nsImage, ciImage: ciImage)
                        }
                    }
                    if let cgImage = FullScreenImageCache.loadDownsampled(
                        from: selectedImageURL,
                        maxPixelSize: previewMaxPixelSize
                    ) {
                        let image = NSImage(
                            cgImage: cgImage,
                            size: NSSize(width: cgImage.width, height: cgImage.height)
                        )
                        return (image: image, ciImage: CIImage(cgImage: cgImage))
                    }
                    if let image = NSImage(contentsOf: selectedImageURL) {
                        let ciImage = image.tiffRepresentation.flatMap { CIImage(data: $0) }
                        return (image: image, ciImage: ciImage)
                    }
                    return (image: nil, ciImage: nil)
                }.value

                guard !Task.isCancelled else { return }

                if let image = previewSource.image {
                    sourceImage = image
                    sourceCIImage = previewSource.ciImage
                } else {
                    let thumbnail = await browserViewModel.thumbnailService.loadThumbnail(for: selectedImageURL)
                    guard !Task.isCancelled else { return }
                    sourceImage = thumbnail
                    sourceCIImage = thumbnail?.tiffRepresentation.flatMap { CIImage(data: $0) }
                }

                // Upload source to Metal texture for compute shader fast path.
                if let ci = sourceCIImage, let pipeline = metalPipeline {
                    await Task.detached(priority: .medium) {
                        pipeline.uploadSourceImage(ci)
                    }.value
                    guard !Task.isCancelled else { return }
                    renderPreview()
                }

                renderPreview()
                isLoadingPreview = false
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

        var adjacentRAWURLs: [URL] = []
        if currentIndex > 0 {
            let prevURL = images[currentIndex - 1].url
            if SupportedImageFormats.isRaw(url: prevURL) { adjacentRAWURLs.append(prevURL) }
        }
        if currentIndex < images.count - 1 {
            let nextURL = images[currentIndex + 1].url
            if SupportedImageFormats.isRaw(url: nextURL) { adjacentRAWURLs.append(nextURL) }
        }

        guard !adjacentRAWURLs.isEmpty else { return }
        let screenMaxPx = previewWorkingMaxPixelSize
        editLog.info("[\(currentURL.lastPathComponent)] precacheAdjacent: \(adjacentRAWURLs.map(\.lastPathComponent)) at \(Int(screenMaxPx))px")

        Task.detached(priority: .background) {
            for url in adjacentRAWURLs {
                guard !Task.isCancelled else {
                    editLog.info("[\(url.lastPathComponent)] precache: cancelled")
                    return
                }
                let start = ContinuousClock.now
                guard let ciImage = FullScreenImageCache.loadHDRPreview(
                    from: url, maxPixelSize: screenMaxPx
                ) else {
                    editLog.info("[\(url.lastPathComponent)] precache: decode failed")
                    continue
                }
                pipeline.precacheTexture(for: url, ciImage: ciImage)
                let elapsed = ContinuousClock.now - start
                editLog.info("[\(url.lastPathComponent)] precache: done in \(elapsed)")
            }
        }
    }

    private func renderPreview() {
        let renderStart = ContinuousClock.now
        guard let sourceCIImage else {
            previewCIImage = nil
            previewImage = sourceImage
            previewCGImage = nil
            NotificationCenter.default.post(name: .scopeSourceImageDidChange, object: nil, userInfo: ["isHDR": isHDREnabled])
            return
        }

        let settings = metadataViewModel.editingMetadata.cameraRaw

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
            // Metal overlay is only used during active drags — SwiftUI handles static display
            pipeline.updateOverlayParams(geometry: nil, visible: false)
            metalCoordinator.requestRedraw()
        }
        if lockedCropImageRect != nil {
            editLog.debug("renderPreview: crop interaction path (full-res Metal, skip CGImage)")
            return
        }

        editLog.debug("renderPreview: full path (CGImage generation)")
        // Build CIFilter chain as fallback CIImage (used if Metal compute is unavailable,
        // e.g. during "before" toggle, and as source for CGImage generation).
        previewCIImage = CameraRawApproximation.apply(to: sourceCIImage, settings: settings)

        // On release / initial load: produce CGImage for scope display and export
        previewRenderTask?.cancel()
        let fullSource = sourceCIImage
        let fallback = sourceImage
        let orientation = selectedImageOrientation

        let hdr = isHDREnabled
        previewRenderTask = Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (NSImage, CGImage, CGImage?)? in
                let output = CameraRawApproximation.apply(to: fullSource, settings: settings)
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
                previewCGImage = result.1
                NotificationCenter.default.post(name: .scopeSourceImageDidChange, object: nil, userInfo: ["cgImage": result.2 ?? result.1, "isHDR": hdr])
            } else {
                previewImage = fallback
                previewCGImage = nil
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
        let settings = metadataViewModel.editingMetadata.cameraRaw
        let hdr = isHDREnabled
        let orientation = selectedImageOrientation

        let maxDim: CGFloat = 360
        let extent = sourceCIImage.extent
        let scale = min(maxDim / extent.width, maxDim / extent.height, 1.0)
        let small = sourceCIImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let filtered = CameraRawApproximation.apply(to: small, settings: settings)
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
        let hasC2PA = browserViewModel.selectedImages.contains { $0.hasC2PA }
        let mode = hasC2PA ? settingsViewModel.metadataWriteModeC2PA : settingsViewModel.metadataWriteModeNonC2PA
        let effectiveMode: MetadataWriteMode = {
            guard mode == .writeToXMPSidecar,
                  let selectedURL = selectedImageURL,
                  !SupportedImageFormats.isRaw(url: selectedURL) else {
                return mode
            }
            // ACR-compatible behavior for non-RAW files: write XMP into the file.
            return .writeToFile
        }()

        // Sync cameraRaw to ImageFile so the thumbnail reflects edits immediately
        syncCameraRawToImageFile()

        if hasC2PA, effectiveMode == .writeToFile {
            // Can't write to file — save to JSON sidecar + XMP sidecar
            metadataViewModel.commitEdits(
                mode: .writeToXMPSidecar,
                hasC2PA: hasC2PA
            ) {
                onPendingStatusChanged?()
            }
            return
        }

        metadataViewModel.commitEdits(
            mode: effectiveMode,
            hasC2PA: hasC2PA
        ) {
            onPendingStatusChanged?()
        }
    }

    private func syncCameraRawToImageFile() {
        guard let url = selectedImageURL,
              let index = browserViewModel.urlToImageIndex[url] else { return }
        let newSettings = metadataViewModel.editingMetadata.cameraRaw
        let oldSettings = browserViewModel.images[index].cameraRawSettings
        guard newSettings != oldSettings else { return }
        browserViewModel.images[index].cameraRawSettings = newSettings
        browserViewModel.images[index].hasDevelopEdits = newSettings != nil && !newSettings!.isEmpty
        browserViewModel.images[index].hasCropEdits = newSettings?.crop?.isEmpty == false
        browserViewModel.thumbnailService.invalidateThumbnail(for: url)
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

        // AABB crop dimensions in image pixels
        let aabbW = crop.width * imageSize.width
        let aabbH = crop.height * imageSize.height

        // Forward project AABB to actual (rotated) crop pixel dimensions
        let radians = angleDegrees * Double.pi / 180.0
        let cosA = cos(radians)
        let sinA = sin(radians)
        let actualW: Double
        let actualH: Double
        if abs(radians) > 0.000001 {
            actualW = abs(aabbW * cosA + aabbH * sinA)
            actualH = abs(-aabbW * sinA + aabbH * cosA)
        } else {
            actualW = aabbW
            actualH = aabbH
        }

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
    /// Uses the same forward projection math as CropOverlayView.viewCropRect.
    private func cropViewRect(crop: NormalizedCropRegion, angleDegrees: Double, imageRect: CGRect) -> CGRect {
        let A = -angleDegrees * Double.pi / 180.0
        let cosA = cos(A)
        let sinA = sin(A)

        // AABB center offset from image center in image-rect pixel units
        let imgCX = (crop.centerX - 0.5) * imageRect.width
        let imgCY = (crop.centerY - 0.5) * imageRect.height

        // Rotate center offset to view space
        let viewCX = imgCX * cosA - imgCY * sinA + imageRect.midX
        let viewCY = imgCX * sinA + imgCY * cosA + imageRect.midY

        // Forward project AABB dims to actual crop dims
        let aabbW = crop.width * imageRect.width
        let aabbH = crop.height * imageRect.height
        let radians = angleDegrees * Double.pi / 180.0
        let actualW: Double
        let actualH: Double
        if abs(radians) > 0.000001 {
            let cosR = cos(radians)
            let sinR = sin(radians)
            actualW = abs(aabbW * cosR + aabbH * sinR)
            actualH = abs(-aabbW * sinR + aabbH * cosR)
        } else {
            actualW = aabbW
            actualH = aabbH
        }

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

    private func updateCameraRaw(_ update: (inout CameraRawSettings) -> Void) {
        let oldSettings = metadataViewModel.editingMetadata.cameraRaw
        var cameraRaw = oldSettings ?? CameraRawSettings()
        update(&cameraRaw)
        cameraRaw.hasSettings = cameraRawHasEdits(cameraRaw) ? true : nil
        let newSettings = cameraRawHasEdits(cameraRaw) ? cameraRaw : nil
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
            || (cameraRaw.crop?.isEmpty == false)
            || !(cameraRaw.localAdjustments?.isEmpty ?? true)
    }

    private func toneSliderBinding(_ keyPath: WritableKeyPath<CameraRawSettings, Int?>) -> Binding<Double> {
        Binding(
            get: { Double(metadataViewModel.editingMetadata.cameraRaw?[keyPath: keyPath] ?? 0) },
            set: { newValue in
                updateCameraRaw { cameraRaw in
                    cameraRaw[keyPath: keyPath] = Int(newValue.rounded())
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
                    cameraRaw.exposure2012 = (newValue * 100).rounded() / 100
                }
            }
        )
    }

    private var whiteBalanceTemperatureBinding: Binding<Double> {
        Binding(
            get: {
                if usesIncrementalWhiteBalance {
                    return Double(metadataViewModel.editingMetadata.cameraRaw?.incrementalTemperature ?? 0)
                }
                let value = Double(metadataViewModel.editingMetadata.cameraRaw?.temperature ?? 6500)
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
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Temperature (K)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if abs(whiteBalanceTemperatureBinding.wrappedValue - 6500) > 1 {
                    Button {
                        whiteBalanceTemperatureBinding.wrappedValue = 6500
                        commitEditAdjustments()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Reset to 6500K")
                }
                Spacer()
                Text("\(Int(whiteBalanceTemperatureBinding.wrappedValue.rounded()))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            EditSlider(
                value: whiteBalanceTemperatureLogBinding,
                range: 0...1,
                step: 0,
                gradientColors: [.blue, .yellow],
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
                        pipeline.updateParams(settings)
                        metalCoordinator.requestRedraw()
                    }
                },
                onReset: {
                    whiteBalanceTemperatureBinding.wrappedValue = 6500
                    commitEditAdjustments()
                }
            )
            .frame(height: 20)
        }
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
                return Double(metadataViewModel.editingMetadata.cameraRaw?.tint ?? 0)
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
            selectedMaskIndex = nil
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
            let oldAngle = displayCrop.angle ?? 0
            let region = NormalizedCropRegion(
                top: displayCrop.top ?? 0,
                left: displayCrop.left ?? 0,
                bottom: displayCrop.bottom ?? 1,
                right: displayCrop.right ?? 1
            )
            .withAngle(from: oldAngle, to: clampedAngle, aspectRatio: ar)
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
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let onReset, abs(value.wrappedValue) > 0.001 {
                    Button {
                        onReset()
                        commitEditAdjustments()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Reset to default")
                }
                Spacer()
                Text(formatter(value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            EditSlider(
                value: value,
                range: range,
                step: step,
                gradientColors: gradientColors,
                onEditingChanged: { editing in
                    isDraggingEditSlider = editing
                    if !editing {
                        commitEditAdjustments()
                    }
                },
                onDragValueChanged: settingsMutator.map { mutator in
                    { dragValue in
                        // Build temporary settings with the drag value applied,
                        // bypassing SwiftUI observation on the ViewModel.
                        if let pipeline = metalPipeline, pipeline.hasSourceTexture {
                            var settings = metadataViewModel.editingMetadata.cameraRaw ?? CameraRawSettings()
                            mutator(&settings, dragValue)
                            pipeline.updateParams(settings)
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
            .frame(height: 20)
        }
    }

    // MARK: - Mask UI

    private var maskSelectorBar: some View {
        HStack(spacing: 6) {
            Button {
                addNewMask()
            } label: {
                Image(systemName: "plus.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Add mask adjustment")

            let masks = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments ?? []
            Picker("", selection: $selectedMaskIndex) {
                Text("Global").tag(nil as Int?)
                ForEach(Array(masks.enumerated()), id: \.offset) { idx, mask in
                    Text(mask.name).tag(idx as Int?)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity)

            if let idx = selectedMaskIndex {
                let masks = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments ?? []
                if idx < masks.count {
                    Button {
                        let inverted = masks[idx].inverted
                        updateCameraRaw { cameraRaw in
                            cameraRaw.localAdjustments?[idx].inverted = !inverted
                        }
                        commitEditAdjustments()
                    } label: {
                        Image(systemName: masks[idx].inverted ? "circle.dashed.inset.filled" : "circle.dashed")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(masks[idx].inverted ? "Invert: adjustments apply outside ellipse" : "Normal: adjustments apply inside ellipse")

                    Button {
                        let enabled = masks[idx].enabled
                        updateCameraRaw { cameraRaw in
                            cameraRaw.localAdjustments?[idx].enabled = !enabled
                        }
                        commitEditAdjustments()
                    } label: {
                        Image(systemName: masks[idx].enabled ? "eye" : "eye.slash")
                            .font(.system(size: 11))
                            .foregroundStyle(masks[idx].enabled ? Color.secondary : Color.red)
                    }
                    .buttonStyle(.plain)
                    .help(masks[idx].enabled ? "Mute mask effect" : "Enable mask effect")
                }

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
        }
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

    private func addNewMask() {
        let existingCount = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments?.count ?? 0
        var geo = EllipseMaskGeometry()
        // Make the mask a circle by compensating for image aspect ratio
        if let size = currentImageSize, size.height > 0 {
            geo.radiusY = geo.radiusX * size.width / size.height
        }
        let newMask = MaskAdjustment(name: "Mask \(existingCount + 1)", geometry: geo)
        updateCameraRaw { cameraRaw in
            if cameraRaw.localAdjustments == nil {
                cameraRaw.localAdjustments = []
            }
            cameraRaw.localAdjustments?.append(newMask)
        }
        selectedMaskIndex = existingCount
        commitEditAdjustments()
    }

    private func deleteSelectedMask() {
        guard let idx = selectedMaskIndex,
              let masks = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments,
              idx < masks.count else { return }
        updateCameraRaw { cameraRaw in
            cameraRaw.localAdjustments?.remove(at: idx)
            if cameraRaw.localAdjustments?.isEmpty == true {
                cameraRaw.localAdjustments = nil
            }
        }
        let remaining = metadataViewModel.editingMetadata.cameraRaw?.localAdjustments?.count ?? 0
        if remaining == 0 {
            selectedMaskIndex = nil
        } else {
            selectedMaskIndex = min(idx, remaining - 1)
        }
        commitEditAdjustments()
    }

    private var isSelectedImageRaw: Bool {
        guard let url = selectedImageURL else { return false }
        return SupportedImageFormats.isRaw(url: url)
    }

    private func resetDevelopAdjustments() {
        resetCropZoom()
        selectedMaskIndex = nil
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
        }
        selectedMaskIndex = nil
        commitEditAdjustments()
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
                let outputURL = try await Task.detached(priority: .userInitiated) {
                    try await EditedImageRenderer.render(from: selectedImageURL, cameraRaw: settings, isHDR: hdr, outputFolder: outputFolder)
                }.value
                browserViewModel.thumbnailService.invalidateThumbnail(for: outputURL)
            } catch {
                browserViewModel.errorMessage = "Failed to save image: \(error.localizedDescription)"
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
                if includeCrop, cameraRaw.crop?.hasCrop == true {
                    browserViewModel.images[index].hasCropEdits = true
                }
                browserViewModel.thumbnailService.invalidateThumbnail(for: url)
            }
        }

        // Write camera raw settings to XMP in the image files
        let targetURLs = Array(urls)
        Task {
            var fields: [String: String] = [:]
            fields[ExifToolWriteTag.crsVersion] = cameraRaw.version ?? "15.4"
            fields[ExifToolWriteTag.crsProcessVersion] = cameraRaw.processVersion ?? "15.4"
            fields[ExifToolWriteTag.crsWhiteBalance] = cameraRaw.whiteBalance ?? ""
            fields[ExifToolWriteTag.crsTemperature] = cameraRaw.temperature.map(String.init) ?? ""
            fields[ExifToolWriteTag.crsTint] = cameraRaw.tint.map(String.init) ?? ""
            fields[ExifToolWriteTag.crsIncrementalTemperature] = cameraRaw.incrementalTemperature.map(String.init) ?? ""
            fields[ExifToolWriteTag.crsIncrementalTint] = cameraRaw.incrementalTint.map(String.init) ?? ""
            fields[ExifToolWriteTag.crsExposure2012] = cameraRaw.exposure2012.map { String(format: "%.2f", $0) } ?? ""
            fields[ExifToolWriteTag.crsContrast2012] = cameraRaw.contrast2012.map(String.init) ?? ""
            fields[ExifToolWriteTag.crsHighlights2012] = cameraRaw.highlights2012.map(String.init) ?? ""
            fields[ExifToolWriteTag.crsShadows2012] = cameraRaw.shadows2012.map(String.init) ?? ""
            fields[ExifToolWriteTag.crsWhites2012] = cameraRaw.whites2012.map(String.init) ?? ""
            fields[ExifToolWriteTag.crsBlacks2012] = cameraRaw.blacks2012.map(String.init) ?? ""
            fields[ExifToolWriteTag.crsSaturation] = cameraRaw.saturation.map(String.init) ?? ""
            fields[ExifToolWriteTag.crsHasSettings] = "True"

            if let crop = cameraRaw.crop, !crop.isEmpty {
                fields[ExifToolWriteTag.crsCropTop] = crop.top.map { String(format: "%.6f", $0) } ?? ""
                fields[ExifToolWriteTag.crsCropLeft] = crop.left.map { String(format: "%.6f", $0) } ?? ""
                fields[ExifToolWriteTag.crsCropBottom] = crop.bottom.map { String(format: "%.6f", $0) } ?? ""
                fields[ExifToolWriteTag.crsCropRight] = crop.right.map { String(format: "%.6f", $0) } ?? ""
                fields[ExifToolWriteTag.crsCropAngle] = crop.angle.map { String(format: "%.6f", $0) } ?? ""
                fields[ExifToolWriteTag.crsHasCrop] = "True"
            }

            do {
                try await browserViewModel.exifToolService.writeFields(fields, to: targetURLs)
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

    private func resetEditZoom() {
        editZoomScale = 1.0
        lastEditZoomScale = 1.0
        editOffset = .zero
        lastEditOffset = .zero
    }

    private func handleEditScrollZoom(delta: CGFloat, event: NSEvent) {
        let zoomFactor = 1.0 + (delta * 0.01)
        let oldScale = editZoomScale
        let newScale = (oldScale * zoomFactor).clamped(to: 1.0...maxEditZoom)
        guard newScale != oldScale else { return }

        // Cursor-anchored zoom: keep content under cursor fixed
        let cursorFromCenter = editCursorFromCenter(event: event)
        let ratio = newScale / oldScale
        let newOffset = CGSize(
            width: editOffset.width * ratio + cursorFromCenter.width * (1 - ratio),
            height: editOffset.height * ratio + cursorFromCenter.height * (1 - ratio)
        )

        withAnimation(.easeOut(duration: 0.1)) {
            editZoomScale = newScale
            lastEditZoomScale = newScale
            if newScale <= 1.0 {
                editOffset = .zero
                lastEditOffset = .zero
            } else {
                editOffset = newOffset
                lastEditOffset = newOffset
            }
        }
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
            }
            .onEnded { _ in
                guard editZoomScale > 1.0 else {
                    editOffset = .zero
                    lastEditOffset = .zero
                    return
                }
                lastEditOffset = editOffset
                constrainEditOffset(in: containerSize, imageSize: imageSize)
            }
    }

    private func constrainEditOffset(in containerSize: CGSize, imageSize: CGSize) {
        let imageRect = fittedImageRect(in: containerSize, imageSize: imageSize)
        let scaledWidth = imageRect.width * editZoomScale
        let scaledHeight = imageRect.height * editZoomScale
        let maxOffsetX = max(0, (scaledWidth - containerSize.width) / 2)
        let maxOffsetY = max(0, (scaledHeight - containerSize.height) / 2)
        withAnimation(.easeOut(duration: 0.2)) {
            editOffset = CGSize(
                width: editOffset.width.clamped(to: -maxOffsetX...maxOffsetX),
                height: editOffset.height.clamped(to: -maxOffsetY...maxOffsetY)
            )
            lastEditOffset = editOffset
        }
    }

    private func toggleEditZoom() {
        guard let imageSize = currentImageSize else { return }
        let containerSize = previewPaneFrame.size
        guard containerSize.width > 0, containerSize.height > 0 else { return }

        let zoom100 = calculateEditZoomTo100(in: containerSize, imageSize: imageSize)
        let isAt100 = abs(editZoomScale - zoom100) < 0.01

        withAnimation(.easeInOut(duration: 0.2)) {
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
        }
    }

    private func calculateEditZoomTo100(in containerSize: CGSize, imageSize: CGSize) -> CGFloat {
        let imageRect = fittedImageRect(in: containerSize, imageSize: imageSize)
        guard imageRect.width > 0 else { return 1.0 }
        let backingScale = NSScreen.main?.backingScaleFactor ?? 2.0
        // At zoom100, 1 source pixel = 1 physical screen pixel
        return imageSize.width / (imageRect.width * backingScale)
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

        // D key — hold to disable develop adjustments (keep crop visible)
        if chars == "d" {
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
