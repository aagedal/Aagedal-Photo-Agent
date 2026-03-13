import AppKit
import CoreImage
import SwiftUI

struct EditWorkspaceView: View {
    @Bindable var metadataViewModel: MetadataViewModel
    @Bindable var browserViewModel: BrowserViewModel
    let settingsViewModel: SettingsViewModel
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
    @State private var isSavingRenderedJPEG = false
    @State private var copyPasteFeedback: String?
    @State private var cropZoomScale: CGFloat = 1.0
    @State private var lastCropZoomScale: CGFloat = 1.0
    @State private var cropAspectRatio: CropAspectRatio = .original
    @State private var isCursorOverPreview = false
    @State private var scrollEventMonitor: Any?
    @State private var keyEventMonitor: Any?
    @State private var isShowingBefore = false
    @State private var showCropControls = false
    @State private var lockedCropImageRect: CGRect?
    @State private var editUndoManager = UndoManager()
    @State private var metalPipeline: MetalEditPipeline?
    @State private var metalCoordinator = MetalPreviewView.Coordinator()
    @FocusState private var isWorkspaceFocused: Bool

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
        isShowingBefore ? sourceCIImage : (previewCIImage ?? sourceCIImage)
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
    }

    /// Whether the compute shader can handle all active edit operations.
    /// Returns false when contrast, highlights, shadows, whites, or blacks are set,
    /// since those require CIFilter for accurate extended-range rendering.
    private var canUseComputeShader: Bool {
        guard let cameraRaw = metadataViewModel.editingMetadata.cameraRaw else { return true }
        return cameraRaw.contrast2012 == nil
            && cameraRaw.highlights2012 == nil
            && cameraRaw.shadows2012 == nil
            && cameraRaw.whites2012 == nil
            && cameraRaw.blacks2012 == nil
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
        .clamped()
    }

    private var activeCropAngle: Double {
        metadataViewModel.editingMetadata.cameraRaw?.crop?.angle ?? 0
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
            }
            loadSelectedImagePreview()
            keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
                return handleKeyEvent(event)
            }
        }
        .onDisappear {
            previewTask?.cancel()
            previewTask = nil
            previewRenderTask?.cancel()
            previewRenderTask = nil
            if let monitor = keyEventMonitor {
                NSEvent.removeMonitor(monitor)
                keyEventMonitor = nil
            }
        }
        .onChange(of: browserViewModel.selectedImageIDs) { _, _ in
            ensureAtLeastOneSelected()
        }
        .onChange(of: selectedImageURL) { _, _ in
            loadSelectedImagePreview()
        }
        .onChange(of: metadataViewModel.editingMetadata.cameraRaw) { _, _ in
            renderPreview()
        }
        .onChange(of: isDraggingEditSlider) { wasDragging, isDragging in
            if wasDragging, !isDragging {
                renderPreview()
            }
        }
        .onChange(of: selectedImage?.exifOrientation) { _, _ in
            loadSelectedImagePreview()
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
                Color(nsColor: .windowBackgroundColor)

                if let imageSize = currentImageSize, displayCIImage != nil {
                    if (showCropControls || isCropEnabled), !isShowingBefore {
                        // Crop-centered: image scales/positions so crop fills view
                        let zoom = showCropControls ? cropZoomScale : 1.0
                        let computedImageRect = cropFittedImageRect(
                            in: geometry.size,
                            imageSize: imageSize,
                            crop: activeCrop,
                            angleDegrees: activeCropAngle,
                            zoom: zoom
                        )
                        // Lock image rect during crop interaction to prevent
                        // image rescaling while the overlay stays stable
                        let imageRect = lockedCropImageRect ?? computedImageRect

                        MetalPreviewView(
                            ciImage: displayCIImage,
                            isHDR: isHDREnabled,
                            metalPipeline: metalPipeline,
                            useComputeShader: isDraggingEditSlider && canUseComputeShader && metalPipeline?.hasSourceTexture == true,
                            coordinator: metalCoordinator
                        )
                            .frame(width: imageRect.width, height: imageRect.height)
                            .rotationEffect(.degrees(-activeCropAngle))
                            .position(x: imageRect.midX, y: imageRect.midY)

                        if showCropControls, canEditSingleImage {
                            CropOverlayView(
                                imageRect: imageRect,
                                viewSize: geometry.size,
                                crop: activeCrop,
                                angle: activeCropAngle,
                                aspectRatio: cropAspectRatio,
                                imageAspectRatio: sourceAspectRatio,
                                onChange: { newCrop in
                                    if lockedCropImageRect == nil {
                                        lockedCropImageRect = computedImageRect
                                    }
                                    updateCrop(newCrop, commit: false)
                                },
                                onAngleChange: { newAngle in
                                    if lockedCropImageRect == nil {
                                        lockedCropImageRect = computedImageRect
                                    }
                                    updateCropAngle(newAngle, commit: false)
                                },
                                onCommit: {
                                    lockedCropImageRect = nil
                                    commitEditAdjustments()
                                }
                            )
                        }
                    } else {
                        // Normal fit: image fits within view (also used for "before" preview)
                        let imageRect = fittedImageRect(in: geometry.size, imageSize: imageSize)

                        MetalPreviewView(
                            ciImage: displayCIImage,
                            isHDR: isHDREnabled && !isShowingBefore,
                            metalPipeline: metalPipeline,
                            useComputeShader: isDraggingEditSlider && canUseComputeShader && metalPipeline?.hasSourceTexture == true,
                            coordinator: metalCoordinator
                        )
                            .frame(width: imageRect.width, height: imageRect.height)
                            .position(x: geometry.size.width * 0.5, y: geometry.size.height * 0.5)
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
            }
            .clipped()
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
                        guard showCropControls else { return }
                        // Dampen magnification: lerp between 1.0 (no change) and raw value
                        let dampened = 1.0 + (value.magnification - 1.0) * 0.4
                        cropZoomScale = (lastCropZoomScale * dampened).clamped(to: 0.25...3.0)
                    }
                    .onEnded { _ in
                        guard showCropControls else { return }
                        lastCropZoomScale = cropZoomScale
                    }
            )
            .onAppear {
                scrollEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                    guard isCursorOverPreview, showCropControls else { return event }
                    // Only handle direct scroll input, ignore momentum to avoid drift
                    guard event.phase != [] || event.momentumPhase == [] else { return event }
                    let delta = event.scrollingDeltaY
                    guard abs(delta) > 0.01 else { return event }
                    let zoomFactor = 1.0 + (delta * 0.005)
                    let newScale = (cropZoomScale * zoomFactor).clamped(to: 0.25...3.0)
                    cropZoomScale = newScale
                    lastCropZoomScale = newScale
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
            VStack(alignment: .leading, spacing: 8) {
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
                }

                HStack {
                    Text("Develop")
                        .font(.headline)
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
                            gradient: LinearGradient(colors: [.blue, .yellow], startPoint: .leading, endPoint: .trailing),
                            formatter: signedIntString,
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
                        gradient: LinearGradient(colors: [.green, .pink], startPoint: .leading, endPoint: .trailing),
                        formatter: signedIntString,
                        onReset: {
                            whiteBalanceTintBinding.wrappedValue = 0
                        }
                    )

                    sliderRow("Saturation", value: toneSliderBinding(\.saturation), range: -100...100, step: 1, gradient: LinearGradient(colors: [.gray, .red], startPoint: .leading, endPoint: .trailing), formatter: signedIntString, onReset: {
                        toneSliderBinding(\.saturation).wrappedValue = 0
                    })
                    sliderRow("Vibrance", value: toneSliderBinding(\.vibrance), range: -100...100, step: 1, gradient: LinearGradient(colors: [.gray, .orange], startPoint: .leading, endPoint: .trailing), formatter: signedIntString, onReset: {
                        toneSliderBinding(\.vibrance).wrappedValue = 0
                    })

                    // ── Exposure ──
                    Text("Exposure")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    Divider()

                    sliderRow(
                        "Exposure",
                        value: exposureBinding,
                        range: -5...5,
                        step: 0.01,
                        formatter: { signedDoubleString($0, precision: 2) },
                        onReset: {
                            exposureBinding.wrappedValue = 0
                        }
                    )

                    sliderRow("Contrast", value: toneSliderBinding(\.contrast2012), range: -100...100, step: 1, formatter: signedIntString, onReset: {
                        toneSliderBinding(\.contrast2012).wrappedValue = 0
                    })
                    sliderRow("Highlights", value: toneSliderBinding(\.highlights2012), range: -100...100, step: 1, formatter: signedIntString, onReset: {
                        toneSliderBinding(\.highlights2012).wrappedValue = 0
                    })
                    sliderRow("Shadows", value: toneSliderBinding(\.shadows2012), range: -100...100, step: 1, formatter: signedIntString, onReset: {
                        toneSliderBinding(\.shadows2012).wrappedValue = 0
                    })
                    sliderRow("Whites", value: toneSliderBinding(\.whites2012), range: -100...100, step: 1, formatter: signedIntString, onReset: {
                        toneSliderBinding(\.whites2012).wrappedValue = 0
                    })
                    sliderRow("Blacks", value: toneSliderBinding(\.blacks2012), range: -100...100, step: 1, formatter: signedIntString, onReset: {
                        toneSliderBinding(\.blacks2012).wrappedValue = 0
                    })

                    // ── Crop ──
                    Text("Crop")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
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

                    if showCropControls {
                        HStack {
                            Button("Reset Crop") {
                                resetCrop()
                            }
                            .disabled(!isCropEnabled)
                        }

                        Picker("Aspect Ratio", selection: $cropAspectRatio) {
                            ForEach(CropAspectRatio.allCases) { ratio in
                                Text(ratio.label).tag(ratio)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: cropAspectRatio) { _, newRatio in
                            applyAspectRatioToCrop(newRatio)
                        }

                        sliderRow(
                            "Crop Rotation",
                            value: cropAngleBinding,
                            range: -45...45,
                            step: 0.01,
                            formatter: { signedDoubleString($0, precision: 2) },
                            onReset: {
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
        previewTask?.cancel()
        previewTask = nil
        previewRenderTask?.cancel()
        previewRenderTask = nil
        sourceImage = nil
        sourceCIImage = nil
        previewCIImage = nil
        previewImage = nil
        isLoadingPreview = false
        metalPipeline?.clearSourceTexture()
        resetCropZoom()
        showCropControls = isCropEnabled

        guard let selectedImageURL else { return }
        let previewMaxPixelSize = previewWorkingMaxPixelSize
        isLoadingPreview = true

        previewTask = Task {
            guard !Task.isCancelled else { return }

            // Try HDR-preserving path first (keeps float values >1.0 for RAW, HEIC-HLG, AVIF, JXL).
            // Falls back to SDR CGImageSource path for formats CIImage can't decode.
            let previewSource = await Task.detached(priority: .medium) { () -> (image: NSImage?, ciImage: CIImage?) in
                // HDR path: CIImage(contentsOf:) preserves extended-range float data
                if let ciImage = FullScreenImageCache.loadHDRPreview(from: selectedImageURL, maxPixelSize: previewMaxPixelSize) {
                    let ctx = CameraRawApproximation.ciContext
                    if let cgImage = ctx.createCGImage(ciImage, from: ciImage.extent, format: .RGBAh, colorSpace: CameraRawApproximation.workingColorSpace) {
                        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                        return (image: nsImage, ciImage: ciImage)
                    }
                }
                // SDR fallback: CGImageSource thumbnail (fast, but clamps to SDR)
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

            // Upload source to Metal texture for compute shader fast path
            if let ci = sourceCIImage, let pipeline = metalPipeline {
                let ciCopy = ci
                Task.detached(priority: .medium) {
                    pipeline.uploadSourceImage(ciCopy)
                }
            }

            renderPreview()
            isLoadingPreview = false
        }
    }

    private func renderPreview() {
        guard let sourceCIImage else {
            previewCIImage = nil
            previewImage = sourceImage
            previewCGImage = nil
            NotificationCenter.default.post(name: .scopeSourceImageDidChange, object: nil, userInfo: nil)
            return
        }

        let settings = metadataViewModel.editingMetadata.cameraRaw

        // Metal compute fast path: only when the shader can handle ALL active operations
        // (exposure, vibrance, saturation, WB). Falls through to CIFilter path when
        // contrast/highlights/shadows/whites/blacks are set.
        if isDraggingEditSlider, canUseComputeShader,
           let pipeline = metalPipeline, pipeline.hasSourceTexture {
            pipeline.updateParams(settings)
            metalCoordinator.requestRedraw()
            return
        }

        // Build lazy CIFilter chain — nearly free, no GPU work happens here.
        // MetalPreviewView renders this directly to its drawable texture.
        previewCIImage = CameraRawApproximation.apply(to: sourceCIImage, settings: settings)

        // During drag: Metal handles display, skip expensive CGImage generation
        if isDraggingEditSlider { return }

        // On release / initial load: also produce CGImage for scope display and export
        previewRenderTask?.cancel()
        let fullSource = sourceCIImage
        let fallback = sourceImage

        previewRenderTask = Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (NSImage, CGImage)? in
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
                return (nsImage, cgImage)
            }.value

            guard !Task.isCancelled else { return }
            if let result {
                previewImage = result.0
                previewCGImage = result.1
                NotificationCenter.default.post(name: .scopeSourceImageDidChange, object: nil, userInfo: ["cgImage": result.1])
            } else {
                previewImage = fallback
                previewCGImage = nil
                NotificationCenter.default.post(name: .scopeSourceImageDidChange, object: nil, userInfo: nil)
            }
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
                gradient: LinearGradient(colors: [.blue, .yellow], startPoint: .leading, endPoint: .trailing),
                onEditingChanged: { editing in
                    isDraggingEditSlider = editing
                    if !editing {
                        commitEditAdjustments()
                    }
                },
                onReset: {
                    whiteBalanceTemperatureBinding.wrappedValue = 6500
                    commitEditAdjustments()
                }
            )
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

        // Convert output ratio to normalized image-space ratio
        let normalizedRatio = targetRatio / sourceAspectRatio

        let current = activeCrop
        let resized = current.resizedToAspectRatio(normalizedRatio)
        updateCrop(resized, commit: true)
    }

    private func updateCrop(_ crop: NormalizedCropRegion, commit: Bool) {
        let angle = metadataViewModel.editingMetadata.cameraRaw?.crop?.angle ?? 0
        let normalized = crop.clamped().fittingRotated(angleDegrees: angle, aspectRatio: sourceAspectRatio)
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
            .clamped()
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

    private func sliderRow(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        gradient: LinearGradient? = nil,
        formatter: @escaping (Double) -> String,
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
                gradient: gradient,
                onEditingChanged: { editing in
                    isDraggingEditSlider = editing
                    if !editing {
                        commitEditAdjustments()
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
    }

    private var isSelectedImageRaw: Bool {
        guard let url = selectedImageURL else { return false }
        return SupportedImageFormats.isRaw(url: url)
    }

    private func resetDevelopAdjustments() {
        resetCropZoom()
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
        }
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
        let sidecarService = MetadataSidecarService()

        for url in urls {
            // Load existing sidecar or create new one
            let sidecar = sidecarService.loadSidecar(for: url, in: folderURL)
            var metadata = sidecar?.metadata ?? IPTCMetadata()
            var cameraRaw = metadata.cameraRaw ?? CameraRawSettings()

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
            cameraRaw.hasSettings = true
            metadata.cameraRaw = cameraRaw

            let updatedSidecar = MetadataSidecar(
                sourceFile: url.lastPathComponent,
                lastModified: Date(),
                pendingChanges: true,
                metadata: metadata,
                imageMetadataSnapshot: sidecar?.imageMetadataSnapshot,
                history: sidecar?.history ?? []
            )
            try? sidecarService.saveSidecar(updatedSidecar, for: url, in: folderURL)

            // Update in-memory ImageFile state
            if let index = browserViewModel.urlToImageIndex[url] {
                browserViewModel.images[index].cameraRawSettings = cameraRaw
                browserViewModel.images[index].hasDevelopEdits = true
                browserViewModel.images[index].hasPendingMetadataChanges = true
                if includeCrop, cameraRaw.crop?.hasCrop == true {
                    browserViewModel.images[index].hasCropEdits = true
                }
                browserViewModel.thumbnailService.invalidateThumbnail(for: url)
            }
        }

        // Reload the currently displayed image's metadata if it was in the paste set
        if let currentURL = selectedImageURL, urls.contains(currentURL) {
            metadataViewModel.loadMetadata(for: browserViewModel.selectedImages, folderURL: folderURL)
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

        return event
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
