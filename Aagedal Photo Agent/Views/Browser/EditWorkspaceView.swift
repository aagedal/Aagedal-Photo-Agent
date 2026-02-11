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
    @State private var previewImage: NSImage?
    @State private var previewCGImage: CGImage?
    @State private var previewTask: Task<Void, Never>?
    @State private var previewRenderTask: Task<Void, Never>?
    @State private var isLoadingPreview = false
    @State private var isSavingRenderedJPEG = false
    @State private var copyPasteFeedback: String?
    @State private var cropZoomScale: CGFloat = 1.0
    @State private var lastCropZoomScale: CGFloat = 1.0
    @State private var isCursorOverPreview = false
    @State private var scrollEventMonitor: Any?
    @State private var isShowingBefore = false
    @FocusState private var isWorkspaceFocused: Bool

    private static let minKelvin = 2000.0
    private static let maxKelvin = 12000.0

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
            loadSelectedImagePreview()
        }
        .onDisappear {
            previewTask?.cancel()
            previewTask = nil
            previewRenderTask?.cancel()
            previewRenderTask = nil
        }
        .onChange(of: browserViewModel.selectedImageIDs) { _, _ in
            ensureSingleSelection()
        }
        .onChange(of: selectedImageURL) { _, _ in
            loadSelectedImagePreview()
        }
        .onChange(of: metadataViewModel.editingMetadata.cameraRaw) { _, _ in
            renderPreview()
        }
        .onChange(of: selectedImage?.exifOrientation) { _, _ in
            loadSelectedImagePreview()
        }
        .onKeyPress(.leftArrow) {
            guard !isTextFieldActive() else { return .ignored }
            browserViewModel.selectPrevious()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard !isTextFieldActive() else { return .ignored }
            browserViewModel.selectNext()
            return .handled
        }
        .onKeyPress(.escape) {
            onExit()
            return .handled
        }
        .onKeyPress("c") {
            guard !isTextFieldActive() else { return .ignored }
            if NSEvent.modifierFlags.contains(.command) {
                guard canEditSingleImage else { return .ignored }
                browserViewModel.copiedCameraRawSettings = metadataViewModel.editingMetadata.cameraRaw
                showCopyPasteFeedback("Copied")
                return .handled
            }
            guard canEditSingleImage else { return .ignored }
            toggleCrop()
            return .handled
        }
        .onKeyPress("v") {
            guard NSEvent.modifierFlags.contains(.command), !isTextFieldActive() else { return .ignored }
            guard canEditSingleImage, let copied = browserViewModel.copiedCameraRawSettings else { return .ignored }
            let withCrop = NSEvent.modifierFlags.contains(.shift)
            pasteCameraRawSettings(copied, includeCrop: withCrop)
            showCopyPasteFeedback(withCrop ? "Pasted (with crop)" : "Pasted")
            return .handled
        }
        .onKeyPress("m", phases: .down) { _ in
            guard !isTextFieldActive(), canEditSingleImage else { return .ignored }
            isShowingBefore = true
            return .handled
        }
        .onKeyPress("m", phases: .up) { _ in
            isShowingBefore = false
            return .handled
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

                if let displayImage {
                    if isCropEnabled, !isShowingBefore {
                        // Crop-centered: image scales/positions so crop fills view
                        let imageRect = cropFittedImageRect(
                            in: geometry.size,
                            imageSize: displayImage.size,
                            crop: activeCrop,
                            angleDegrees: activeCropAngle,
                            zoom: cropZoomScale
                        )

                        if isHDREnabled, let previewCGImage {
                            HDRImageView(cgImage: previewCGImage, isHDR: true)
                                .frame(width: imageRect.width, height: imageRect.height)
                                .rotationEffect(.degrees(-activeCropAngle))
                                .position(x: imageRect.midX, y: imageRect.midY)
                        } else {
                            Image(nsImage: displayImage)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: imageRect.width, height: imageRect.height)
                                .rotationEffect(.degrees(-activeCropAngle))
                                .position(x: imageRect.midX, y: imageRect.midY)
                        }

                        if canEditSingleImage {
                            CropOverlayView(
                                imageRect: imageRect,
                                viewSize: geometry.size,
                                crop: activeCrop,
                                angle: activeCropAngle,
                                onChange: { newCrop in
                                    updateCrop(newCrop, commit: false)
                                },
                                onAngleChange: { newAngle in
                                    updateCropAngle(newAngle, commit: false)
                                },
                                onCommit: {
                                    commitEditAdjustments()
                                }
                            )
                        }
                    } else {
                        // Normal fit: image fits within view (also used for "before" preview)
                        let imageRect = fittedImageRect(in: geometry.size, imageSize: displayImage.size)

                        if isHDREnabled, !isShowingBefore, let previewCGImage {
                            HDRImageView(cgImage: previewCGImage, isHDR: true)
                                .frame(width: imageRect.width, height: imageRect.height)
                                .position(x: geometry.size.width * 0.5, y: geometry.size.height * 0.5)
                        } else {
                            Image(nsImage: displayImage)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: imageRect.width, height: imageRect.height)
                                .position(x: geometry.size.width * 0.5, y: geometry.size.height * 0.5)
                        }
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
                        guard isCropEnabled else { return }
                        cropZoomScale = (lastCropZoomScale * value.magnification).clamped(to: 0.25...3.0)
                    }
                    .onEnded { _ in
                        guard isCropEnabled else { return }
                        lastCropZoomScale = cropZoomScale
                    }
            )
            .onAppear {
                scrollEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                    guard isCursorOverPreview, isCropEnabled else { return event }
                    // Only handle direct scroll input, ignore momentum to avoid drift
                    guard event.phase != [] || event.momentumPhase == [] else { return event }
                    let delta = event.scrollingDeltaY
                    guard abs(delta) > 0.01 else { return event }
                    let zoomFactor = 1.0 + (delta * 0.02)
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
            VStack(alignment: .leading, spacing: 12) {
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
                    Picker("White Balance", selection: whiteBalanceBinding) {
                        Text("As Shot").tag("As Shot")
                        Text("Auto").tag("Auto")
                        Text("Custom").tag("Custom")
                    }
                    .pickerStyle(.segmented)

                    Toggle("Use incremental WB values", isOn: useIncrementalWhiteBalanceBinding)
                        .toggleStyle(.switch)

                    if usesIncrementalWhiteBalance {
                        sliderRow(
                            "WB Temp (Inc)",
                            value: whiteBalanceTemperatureBinding,
                            range: -100...100,
                            step: 1,
                            formatter: signedIntString,
                            onReset: {
                                whiteBalanceTemperatureBinding.wrappedValue = 0
                            }
                        )
                    } else {
                        kelvinTemperatureSliderRow
                    }

                    sliderRow(
                        usesIncrementalWhiteBalance ? "WB Tint (Inc)" : "Tint",
                        value: whiteBalanceTintBinding,
                        range: -150...150,
                        step: 1,
                        formatter: signedIntString,
                        onReset: {
                            whiteBalanceTintBinding.wrappedValue = 0
                        }
                    )

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

                    HStack {
                        Button(isCropEnabled ? "Disable Crop" : "Enable Crop") {
                            toggleCrop()
                        }
                        Button("Reset Crop") {
                            resetCrop()
                        }
                        .disabled(!isCropEnabled)
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
                    .disabled(!isCropEnabled)

                    if isCropEnabled {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("Crop Zoom")
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
                            Slider(
                                value: $cropZoomScale,
                                in: 0.25...3.0,
                                step: 0.01
                            )
                            .simultaneousGesture(
                                TapGesture(count: 2)
                                    .onEnded {
                                        resetCropZoom()
                                    }
                            )
                            .onChange(of: cropZoomScale) { _, _ in
                                lastCropZoomScale = cropZoomScale
                            }
                        }
                    }

                    Divider()

                    Toggle(isOn: hdrToggleBinding) {
                        Label("HDR", systemImage: "sun.max.fill")
                    }
                    .toggleStyle(.switch)
                    .disabled(!canEditSingleImage)

                    Divider()

                    Button(isSavingRenderedJPEG ? "Saving JPEG..." : "Save JPEG") {
                        saveCurrentRenderedJPEG()
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
                        isSelected: image.url == selectedImageURL
                    )
                    .onTapGesture {
                        browserViewModel.selectedImageIDs = [image.url]
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

    private func loadSelectedImagePreview() {
        previewTask?.cancel()
        previewTask = nil
        previewRenderTask?.cancel()
        previewRenderTask = nil
        sourceImage = nil
        sourceCIImage = nil
        previewImage = nil
        isLoadingPreview = false
        resetCropZoom()

        guard let selectedImageURL else { return }
        let previewMaxPixelSize = previewWorkingMaxPixelSize
        isLoadingPreview = true

        previewTask = Task {
            guard !Task.isCancelled else { return }

            let previewSource = await Task.detached(priority: .userInitiated) { () -> (image: NSImage?, ciImage: CIImage?) in
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

            renderPreview()
            isLoadingPreview = false
        }
    }

    private func renderPreview() {
        guard let sourceCIImage else {
            previewImage = sourceImage
            previewCGImage = nil
            return
        }

        previewRenderTask?.cancel()
        let source = sourceCIImage
        let settings = metadataViewModel.editingMetadata.cameraRaw
        let fallback = sourceImage

        previewRenderTask = Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (NSImage, CGImage)? in
                let output = CameraRawApproximation.apply(to: source, settings: settings)
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
            } else {
                previewImage = fallback
                previewCGImage = nil
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

        if hasC2PA, effectiveMode == .writeToFile {
            metadataViewModel.saveToSidecar()
            onPendingStatusChanged?()
            return
        }

        metadataViewModel.commitEdits(
            mode: effectiveMode,
            hasC2PA: hasC2PA
        ) {
            onPendingStatusChanged?()
        }
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
        let cameraRaw = metadataViewModel.editingMetadata.cameraRaw
        if cameraRaw?.temperature != nil || cameraRaw?.tint != nil {
            return false
        }
        if cameraRaw?.incrementalTemperature != nil || cameraRaw?.incrementalTint != nil {
            return true
        }
        return false
    }

    private func updateCameraRaw(_ update: (inout CameraRawSettings) -> Void) {
        var cameraRaw = metadataViewModel.editingMetadata.cameraRaw ?? CameraRawSettings()
        update(&cameraRaw)
        cameraRaw.hasSettings = cameraRawHasEdits(cameraRaw) ? true : nil
        metadataViewModel.editingMetadata.cameraRaw = cameraRawHasEdits(cameraRaw) ? cameraRaw : nil
        metadataViewModel.markChanged()
    }

    private func cameraRawHasEdits(_ cameraRaw: CameraRawSettings) -> Bool {
        cameraRaw.whiteBalance != nil
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

    private var whiteBalanceBinding: Binding<String> {
        Binding(
            get: { metadataViewModel.editingMetadata.cameraRaw?.whiteBalance ?? "Custom" },
            set: { newValue in
                updateCameraRaw { cameraRaw in
                    cameraRaw.whiteBalance = newValue
                }
                commitEditAdjustments()
            }
        )
    }

    private var useIncrementalWhiteBalanceBinding: Binding<Bool> {
        Binding(
            get: { usesIncrementalWhiteBalance },
            set: { enabled in
                updateCameraRaw { cameraRaw in
                    if enabled {
                        cameraRaw.temperature = nil
                        cameraRaw.tint = nil
                        if cameraRaw.incrementalTemperature == nil { cameraRaw.incrementalTemperature = 0 }
                        if cameraRaw.incrementalTint == nil { cameraRaw.incrementalTint = 0 }
                    } else {
                        cameraRaw.incrementalTemperature = nil
                        cameraRaw.incrementalTint = nil
                        if cameraRaw.temperature == nil { cameraRaw.temperature = 6500 }
                        if cameraRaw.tint == nil { cameraRaw.tint = 0 }
                    }
                }
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
                let value = Double(metadataViewModel.editingMetadata.cameraRaw?.temperature ?? 6500)
                return min(max(value, Self.minKelvin), Self.maxKelvin)
            },
            set: { newValue in
                updateCameraRaw { cameraRaw in
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
            Slider(
                value: whiteBalanceTemperatureLogBinding,
                in: 0...1,
                onEditingChanged: { editing in
                    if !editing {
                        commitEditAdjustments()
                    }
                }
            )
            .simultaneousGesture(
                TapGesture(count: 2)
                    .onEnded {
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
                    if usesIncrementalWhiteBalance {
                        cameraRaw.incrementalTint = Int(newValue.rounded())
                    } else {
                        cameraRaw.tint = Int(newValue.rounded())
                    }
                }
            }
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

    private func toggleCrop() {
        resetCropZoom()
        updateCameraRaw { cameraRaw in
            var crop = cameraRaw.crop ?? CameraRawCrop()
            let enabled = !(crop.hasCrop ?? false)
            crop.hasCrop = enabled
            if enabled {
                if crop.top == nil { crop.top = 0 }
                if crop.left == nil { crop.left = 0 }
                if crop.bottom == nil { crop.bottom = 1 }
                if crop.right == nil { crop.right = 1 }
                if crop.angle == nil { crop.angle = 0 }
            }
            cameraRaw.crop = crop
        }
        commitEditAdjustments()
    }

    private func resetCrop() {
        resetCropZoom()
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
            Slider(
                value: value,
                in: range,
                step: step,
                onEditingChanged: { editing in
                    if !editing {
                        commitEditAdjustments()
                    }
                }
            )
            .simultaneousGesture(
                TapGesture(count: 2)
                    .onEnded {
                        guard let onReset else { return }
                        onReset()
                        commitEditAdjustments()
                    }
            )
        }
    }

    private func resetDevelopAdjustments() {
        resetCropZoom()
        updateCameraRaw { cameraRaw in
            cameraRaw.whiteBalance = "Custom"
            cameraRaw.temperature = 6500
            cameraRaw.tint = 0
            cameraRaw.incrementalTemperature = nil
            cameraRaw.incrementalTint = nil
            cameraRaw.exposure2012 = 0
            cameraRaw.contrast2012 = 0
            cameraRaw.highlights2012 = 0
            cameraRaw.shadows2012 = 0
            cameraRaw.whites2012 = 0
            cameraRaw.blacks2012 = 0
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
            cameraRaw.whiteBalance = nil
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
        }
        commitEditAdjustments()
    }

    private func saveCurrentRenderedJPEG() {
        guard !isSavingRenderedJPEG,
              let selectedImageURL else { return }
        let settings = metadataViewModel.editingMetadata.cameraRaw
        isSavingRenderedJPEG = true

        Task {
            do {
                let outputFolder = selectedImageURL.deletingLastPathComponent().appendingPathComponent("Edited", isDirectory: true)
                try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
                try EditedImageRenderer.renderJPEG(from: selectedImageURL, cameraRaw: settings, outputFolder: outputFolder)
                let outputURL = EditedImageRenderer.outputURL(for: selectedImageURL, in: outputFolder)
                browserViewModel.thumbnailService.invalidateThumbnail(for: outputURL)
            } catch {
                browserViewModel.errorMessage = "Failed to save JPEG: \(error.localizedDescription)"
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
            if includeCrop {
                cameraRaw.crop = source.crop
            }
        }
        commitEditAdjustments()
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
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
