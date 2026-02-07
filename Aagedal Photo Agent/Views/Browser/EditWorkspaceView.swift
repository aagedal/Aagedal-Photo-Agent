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
    @State private var previewTask: Task<Void, Never>?
    @State private var previewRenderTask: Task<Void, Never>?
    @State private var isLoadingPreview = false
    @State private var isSavingRenderedJPEG = false
    @FocusState private var isWorkspaceFocused: Bool

    private static let minKelvin = 2000.0
    private static let maxKelvin = 12000.0
    private static let toneLogCurveExponent = 2.2

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

    private var isCropEnabled: Bool {
        metadataViewModel.editingMetadata.cameraRaw?.crop?.hasCrop ?? false
    }

    private var activeCrop: NormalizedCropRegion {
        guard let crop = metadataViewModel.editingMetadata.cameraRaw?.crop else { return .full }
        return NormalizedCropRegion(
            top: crop.top ?? 0,
            left: crop.left ?? 0,
            bottom: crop.bottom ?? 1,
            right: crop.right ?? 1
        )
        .clamped()
    }

    private var activeCropAngle: Double {
        metadataViewModel.editingMetadata.cameraRaw?.crop?.angle ?? 0
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
    }

    private var previewPane: some View {
        GeometryReader { geometry in
            ZStack {
                Color(nsColor: .windowBackgroundColor)

                if let previewImage {
                    let imageRect = fittedImageRect(in: geometry.size, imageSize: previewImage.size)

                    Image(nsImage: previewImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: imageRect.width, height: imageRect.height)
                        .position(x: imageRect.midX, y: imageRect.midY)

                    if isCropEnabled && canEditSingleImage {
                        CropOverlayView(
                            imageRect: imageRect,
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
        }
    }

    private var controlsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Develop")
                        .font(.headline)
                    Spacer()
                    Button("Exit Edit View") {
                        onExit()
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

                    logarithmicToneSliderRow("Contrast", keyPath: \.contrast2012)
                    sliderRow("Highlights", value: toneSliderBinding(\.highlights2012), range: -100...100, step: 1, formatter: signedIntString, onReset: {
                        toneSliderBinding(\.highlights2012).wrappedValue = 0
                    })
                    sliderRow("Shadows", value: toneSliderBinding(\.shadows2012), range: -100...100, step: 1, formatter: signedIntString, onReset: {
                        toneSliderBinding(\.shadows2012).wrappedValue = 0
                    })
                    logarithmicToneSliderRow("Whites", keyPath: \.whites2012)
                    logarithmicToneSliderRow("Blacks", keyPath: \.blacks2012)

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
                        step: 0.1,
                        formatter: { signedDoubleString($0, precision: 1) },
                        onReset: {
                            cropAngleBinding.wrappedValue = 0
                        }
                    )
                    .disabled(!isCropEnabled)

                    Divider()

                    HStack {
                        Button(isSavingRenderedJPEG ? "Saving JPEG..." : "Save JPEG") {
                            saveCurrentRenderedJPEG()
                        }
                        .disabled(!canEditSingleImage || selectedImageURL == nil || isSavingRenderedJPEG)

                        Button("Reset") {
                            resetDevelopAdjustments()
                        }
                    }
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
            return
        }

        previewRenderTask?.cancel()
        let source = sourceCIImage
        let settings = metadataViewModel.editingMetadata.cameraRaw
        let fallback = sourceImage

        previewRenderTask = Task {
            let rendered = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                let output = CameraRawApproximation.apply(to: source, settings: settings)
                guard let cgImage = CameraRawApproximation.ciContext.createCGImage(output, from: output.extent) else {
                    return nil
                }
                return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }.value

            guard !Task.isCancelled else { return }
            previewImage = rendered ?? fallback
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

    private var usesIncrementalWhiteBalance: Bool {
        let cameraRaw = metadataViewModel.editingMetadata.cameraRaw
        if cameraRaw?.temperature != nil || cameraRaw?.tint != nil {
            return false
        }
        return cameraRaw?.incrementalTemperature != nil || cameraRaw?.incrementalTint != nil
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

    @ViewBuilder
    private func logarithmicToneSliderRow(
        _ label: String,
        keyPath: WritableKeyPath<CameraRawSettings, Int?>
    ) -> some View {
        let displayFormatter: (Double) -> String = { _ in
            let current = Double(metadataViewModel.editingMetadata.cameraRaw?[keyPath: keyPath] ?? 0)
            return signedIntString(current)
        }
        sliderRow(
            label,
            value: logarithmicToneSliderBinding(keyPath),
            range: -100...100,
            step: 0.1,
            formatter: displayFormatter,
            onReset: {
                toneSliderBinding(keyPath).wrappedValue = 0
            }
        )
    }

    private func logarithmicToneSliderBinding(_ keyPath: WritableKeyPath<CameraRawSettings, Int?>) -> Binding<Double> {
        Binding(
            get: {
                let actual = Double(metadataViewModel.editingMetadata.cameraRaw?[keyPath: keyPath] ?? 0)
                return sliderValueForTone(actual)
            },
            set: { sliderValue in
                let actual = toneValueForSlider(sliderValue)
                updateCameraRaw { cameraRaw in
                    cameraRaw[keyPath: keyPath] = Int(actual.rounded())
                }
            }
        )
    }

    private func sliderValueForTone(_ toneValue: Double) -> Double {
        let clamped = min(max(toneValue, -100), 100)
        let sign = clamped >= 0 ? 1.0 : -1.0
        let normalized = abs(clamped) / 100.0
        let sliderNormalized = pow(normalized, 1.0 / Self.toneLogCurveExponent)
        return sign * sliderNormalized * 100.0
    }

    private func toneValueForSlider(_ sliderValue: Double) -> Double {
        let clamped = min(max(sliderValue, -100), 100)
        let sign = clamped >= 0 ? 1.0 : -1.0
        let normalized = abs(clamped) / 100.0
        let toneNormalized = pow(normalized, Self.toneLogCurveExponent)
        return sign * toneNormalized * 100.0
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
        let normalized = crop.clamped().fittingRotated(angleDegrees: angle)
        updateCameraRaw { cameraRaw in
            var cameraCrop = cameraRaw.crop ?? CameraRawCrop()
            cameraCrop.top = normalized.top
            cameraCrop.left = normalized.left
            cameraCrop.bottom = normalized.bottom
            cameraCrop.right = normalized.right
            cameraCrop.hasCrop = true
            if cameraCrop.angle == nil {
                cameraCrop.angle = 0
            }
            cameraRaw.crop = cameraCrop
        }
        if commit {
            commitEditAdjustments()
        }
    }

    private func updateCropAngle(_ angle: Double, commit: Bool) {
        let clampedAngle = min(max(angle, -45), 45)
        updateCameraRaw { cameraRaw in
            var cameraCrop = cameraRaw.crop ?? CameraRawCrop(
                top: 0,
                left: 0,
                bottom: 1,
                right: 1,
                angle: 0,
                hasCrop: true
            )
            let region = NormalizedCropRegion(
                top: cameraCrop.top ?? 0,
                left: cameraCrop.left ?? 0,
                bottom: cameraCrop.bottom ?? 1,
                right: cameraCrop.right ?? 1
            )
            .clamped()
            .fittingRotated(angleDegrees: clampedAngle)

            cameraCrop.top = region.top
            cameraCrop.left = region.left
            cameraCrop.bottom = region.bottom
            cameraCrop.right = region.right
            cameraCrop.angle = (clampedAngle * 100).rounded() / 100
            cameraCrop.hasCrop = true
            cameraRaw.crop = cameraCrop
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

    private func isTextFieldActive() -> Bool {
        guard let window = NSApp.keyWindow else { return false }
        if let responder = window.firstResponder {
            return responder is NSText || responder is NSTextView
        }
        return false
    }
}
